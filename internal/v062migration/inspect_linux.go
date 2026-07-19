//go:build linux

package v062migration

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const (
	versionWitness       = "0.62.0\n"
	maxVersionBytes      = 64
	maxMetadataBytes     = 1 << 20
	rollbackDirectory    = ".beads-v0.62.0-rollback"
	directoryOpenFlags   = unix.O_RDONLY | unix.O_DIRECTORY | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NOATIME
	regularFileOpenFlags = unix.O_RDONLY | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NOATIME | unix.O_NONBLOCK
)

var (
	databaseNamePattern       = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]{0,63}$`)
	projectIDPattern          = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)
	errWitnessOutsideBound    = errors.New("witness outside size bound")
	errWitnessChanged         = errors.New("witness changed while read")
	allowedV062MetadataFields = map[string]struct{}{
		"backend":                  {},
		"database":                 {},
		"deletions_retention_days": {},
		"dolt_data_dir":            {},
		"dolt_database":            {},
		"dolt_mode":                {},
		"dolt_remotesapi_port":     {},
		"dolt_server_host":         {},
		"dolt_server_port":         {},
		"dolt_server_tls":          {},
		"dolt_server_user":         {},
		"last_bd_version":          {},
		"project_id":               {},
		"stale_closed_issues_days": {},
	}
)

type metadataShape struct {
	database  string
	projectID string
}

type treeSnapshot struct {
	treeSHA256      string
	structureSHA256 string
	kinds           map[string]byte
}

type mountIDReader func(dirfd int, path string, flags int) (uint64, error)

type pathOpener func(path string, flags int, mode uint32) (int, error)

// sourceFS binds every traversal observation to both the source filesystem
// device and the Linux mount that contained the retained project descriptor.
// st_dev alone cannot distinguish bind mounts on the same filesystem.
type sourceFS struct {
	device      uint64
	mountID     uint64
	readMountID mountIDReader
}

type inspectHooks struct {
	afterFirstTree func()
	mountIDAt      mountIDReader
}

func sameAdmissionObservation(first, second treeSnapshot) bool {
	return first.structureSHA256 == second.structureSHA256 && first.treeSHA256 == second.treeSHA256
}

// Inspect admits only an exact, physical v0.62.0 local Dolt-server source.
// Every source read is rooted at retained O_NOFOLLOW descriptors and no source
// path is opened for writing.
func Inspect(project, targetVersion string) (result Result, returnErr error) {
	return inspectWithHooks(project, targetVersion, inspectHooks{})
}

func inspectWithHooks(project, targetVersion string, hooks inspectHooks) (result Result, returnErr error) {
	if err := checkInspectPreconditions(project); err != nil {
		return Result{}, err
	}

	readMountID := hooks.mountIDAt
	if readMountID == nil {
		readMountID = readMountIDAt
	}
	projectFile, projectStat, projectMountID, err := openProject(project, readMountID)
	if err != nil {
		return Result{}, err
	}
	defer closeForInspection(&result, &returnErr, projectFile)
	fs := sourceFS{device: projectStat.Dev, mountID: projectMountID, readMountID: readMountID}

	beadsFile, beadsStat, err := fs.openDirectoryAt(projectFile, ".beads")
	if err != nil {
		return Result{}, classifyBeadsOpen(err)
	}
	defer closeForInspection(&result, &returnErr, beadsFile)

	if err := rejectRollbackCollision(projectFile); err != nil {
		return Result{}, err
	}

	versionFile, versionStat, version, err := fs.readBoundedWitness(beadsFile, ".local_version", CodeSourceVersionMissing, CodeSourceVersionAmbiguous, maxVersionBytes, CodeSourceVersionMismatch)
	defer closeForInspection(&result, &returnErr, versionFile)
	if err != nil {
		return Result{}, err
	}
	if !bytes.Equal(version, []byte(versionWitness)) {
		return Result{}, refuse(CodeSourceVersionMismatch, false, nil)
	}

	metadataFile, metadataStat, metadata, err := fs.readBoundedWitness(beadsFile, "metadata.json", CodeSourceMetadataMissing, CodeUnsafeSourceSymlink, maxMetadataBytes, CodeSourceMetadataMismatch)
	defer closeForInspection(&result, &returnErr, metadataFile)
	if err != nil {
		return Result{}, err
	}
	shape, err := parseMetadata(metadata)
	if err != nil {
		return Result{}, refuse(CodeSourceMetadataMismatch, false, err)
	}

	first, err := fs.inspectTree(beadsFile, beadsStat, true)
	if err != nil {
		return Result{}, err
	}
	if err := validateRequiredLayout(first.kinds, shape.database); err != nil {
		return Result{}, err
	}
	if hooks.afterFirstTree != nil {
		hooks.afterFirstTree()
	}
	if err := fs.revalidateSource(project, projectFile, projectStat, beadsFile, beadsStat, versionFile, versionStat, metadataFile, metadataStat, version, metadata); err != nil {
		return Result{}, err
	}

	second, err := fs.inspectTree(beadsFile, beadsStat, true)
	if err != nil {
		return Result{}, err
	}
	if !sameAdmissionObservation(first, second) {
		return Result{}, refuse(CodeSourceChanged, true, nil)
	}
	if err := fs.revalidateSource(project, projectFile, projectStat, beadsFile, beadsStat, versionFile, versionStat, metadataFile, metadataStat, version, metadata); err != nil {
		return Result{}, err
	}

	return QualifiedResult(project, targetVersion, shape.database, shape.projectID, first.treeSHA256), nil
}

// checkInspectPreconditions rejects environments and workspace arguments that
// the descriptor-bound inspector cannot admit before any source is opened.
func checkInspectPreconditions(project string) error {
	if runtime.GOARCH != "amd64" {
		return refuse(CodePlatformUnsupported, false, nil)
	}
	wsl, err := runningUnderWSL()
	if err != nil {
		return refuse(CodeSourceUnverifiable, true, err)
	}
	if wsl {
		return refuse(CodePlatformUnsupported, false, nil)
	}
	if !embeddedBuildCapable {
		return refuse(CodeEmbeddedTargetUnavailable, false, nil)
	}
	if project == "" || !filepath.IsAbs(project) {
		return refuse(CodeWorkspaceInvalid, false, nil)
	}
	if filepath.Clean(project) != project {
		return refuse(CodeWorkspaceNotCanonical, false, nil)
	}
	return nil
}

func runningUnderWSL() (bool, error) {
	var name unix.Utsname
	if err := unix.Uname(&name); err != nil {
		return false, err
	}
	return isWSLRelease(utsnameString(name.Release[:])), nil
}

func isWSLRelease(release string) bool {
	lower := strings.ToLower(release)
	return strings.Contains(lower, "microsoft") || strings.Contains(lower, "wsl")
}

func utsnameString(raw []byte) string {
	for index, value := range raw {
		if value == 0 {
			return string(raw[:index])
		}
	}
	return string(raw)
}

func openProject(project string, readMountID mountIDReader) (*os.File, unix.Stat_t, uint64, error) {
	return openProjectWith(project, readMountID, unix.Open)
}

func openProjectWith(project string, readMountID mountIDReader, open pathOpener) (*os.File, unix.Stat_t, uint64, error) {
	fd, err := open(project, directoryOpenFlags, 0)
	if err != nil {
		if errors.Is(err, unix.ELOOP) {
			return nil, unix.Stat_t{}, 0, refuse(CodeWorkspaceNotCanonical, false, err)
		}
		if errors.Is(err, unix.EPERM) || errors.Is(err, unix.EACCES) {
			// O_NOATIME is mandatory: retrying without it would mutate atime and
			// violate the inspector's effect:none contract.
			return nil, unix.Stat_t{}, 0, refuse(CodeSourceUnverifiable, true, err)
		}
		return nil, unix.Stat_t{}, 0, refuse(CodeWorkspaceInvalid, false, err)
	}
	file := os.NewFile(uintptr(fd), project)
	if file == nil {
		_ = unix.Close(fd)
		return nil, unix.Stat_t{}, 0, refuse(CodeSourceUnverifiable, true, nil)
	}
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, 0, refuse(CodeSourceUnverifiable, true, err)
	}
	mountID, err := readMountID(fd, "", unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW)
	if err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, 0, refuse(CodeSourceUnverifiable, true, err)
	}
	canonical, err := os.Readlink(fmt.Sprintf("/proc/self/fd/%d", fd))
	if err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, 0, refuse(CodeSourceUnverifiable, true, err)
	}
	if canonical != project {
		_ = file.Close()
		return nil, unix.Stat_t{}, 0, refuse(CodeWorkspaceNotCanonical, false, nil)
	}
	return file, stat, mountID, nil
}

func readMountIDAt(dirfd int, path string, flags int) (uint64, error) {
	var stat unix.Statx_t
	if err := unix.Statx(dirfd, path, flags, unix.STATX_MNT_ID, &stat); err != nil {
		return 0, err
	}
	if stat.Mask&unix.STATX_MNT_ID == 0 {
		return 0, unix.EOPNOTSUPP
	}
	return stat.Mnt_id, nil
}

func (fs sourceFS) checkMountAt(dirfd int, path string, flags int) error {
	mountID, err := fs.readMountID(dirfd, path, flags)
	if err != nil {
		return refuse(CodeSourceUnverifiable, true, err)
	}
	return checkMountID(mountID, fs.mountID)
}

func checkMountID(actual, expected uint64) error {
	if actual != expected {
		return refuse(CodeCrossDeviceSource, false, nil)
	}
	return nil
}

func (fs sourceFS) openDirectoryAt(parent *os.File, name string) (*os.File, unix.Stat_t, error) {
	var named unix.Stat_t
	if err := unix.Fstatat(int(parent.Fd()), name, &named, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, unix.Stat_t{}, err
	}
	if named.Mode&unix.S_IFMT == unix.S_IFLNK {
		return nil, unix.Stat_t{}, unix.ELOOP
	}
	if named.Mode&unix.S_IFMT != unix.S_IFDIR {
		return nil, unix.Stat_t{}, unix.ENOTDIR
	}
	if err := checkDevice(named.Dev, fs.device); err != nil {
		return nil, unix.Stat_t{}, err
	}
	if err := fs.checkMountAt(int(parent.Fd()), name, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, unix.Stat_t{}, err
	}
	fd, err := unix.Openat(int(parent.Fd()), name, directoryOpenFlags, 0)
	if err != nil {
		return nil, unix.Stat_t{}, err
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		_ = unix.Close(fd)
		return nil, unix.Stat_t{}, unix.EBADF
	}
	var opened unix.Stat_t
	if err := unix.Fstat(fd, &opened); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, err
	}
	if err := checkDevice(opened.Dev, fs.device); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, err
	}
	if err := fs.checkMountAt(fd, "", unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, err
	}
	if !sameStat(named, opened) {
		_ = file.Close()
		return nil, unix.Stat_t{}, unix.ESTALE
	}
	return file, opened, nil
}

func (fs sourceFS) openWitnessAt(parent *os.File, name string, missingCode, symlinkCode Code) (*os.File, unix.Stat_t, error) {
	var named unix.Stat_t
	if err := unix.Fstatat(int(parent.Fd()), name, &named, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil, unix.Stat_t{}, refuse(missingCode, false, err)
		}
		return nil, unix.Stat_t{}, refuse(CodeSourceUnverifiable, true, err)
	}
	switch named.Mode & unix.S_IFMT {
	case unix.S_IFLNK:
		return nil, unix.Stat_t{}, refuse(symlinkCode, false, nil)
	case unix.S_IFREG:
		// Continue below.
	default:
		return nil, unix.Stat_t{}, refuse(CodeUnsafeSourceObject, false, nil)
	}
	if err := checkDevice(named.Dev, fs.device); err != nil {
		return nil, unix.Stat_t{}, err
	}
	if err := fs.checkMountAt(int(parent.Fd()), name, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, unix.Stat_t{}, err
	}
	if named.Nlink != 1 {
		return nil, unix.Stat_t{}, refuse(CodeUnsafeSourceHardlink, false, nil)
	}
	fd, err := unix.Openat(int(parent.Fd()), name, regularFileOpenFlags, 0)
	if err != nil {
		if errors.Is(err, unix.ELOOP) {
			return nil, unix.Stat_t{}, refuse(symlinkCode, false, err)
		}
		return nil, unix.Stat_t{}, refuse(CodeSourceUnverifiable, true, err)
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		_ = unix.Close(fd)
		return nil, unix.Stat_t{}, refuse(CodeSourceUnverifiable, true, nil)
	}
	var opened unix.Stat_t
	if err := unix.Fstat(fd, &opened); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, refuse(CodeSourceUnverifiable, true, err)
	}
	if err := checkDevice(opened.Dev, fs.device); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, err
	}
	if err := fs.checkMountAt(fd, "", unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, err
	}
	if !sameStat(named, opened) {
		_ = file.Close()
		return nil, unix.Stat_t{}, refuse(CodeSourceChanged, true, nil)
	}
	return file, opened, nil
}

// readBoundedWitness opens a required regular-file witness under the retained
// beads descriptor and reads it under the stable-size contract. An oversized
// but stable witness is a non-retryable mismatch. The file is returned even on
// a read failure so the caller can register its deferred close; it is nil only
// when the open itself failed.
func (fs sourceFS) readBoundedWitness(beads *os.File, name string, missingCode, symlinkCode Code, limit int64, mismatchCode Code) (*os.File, unix.Stat_t, []byte, error) {
	file, stat, err := fs.openWitnessAt(beads, name, missingCode, symlinkCode)
	if err != nil {
		return nil, unix.Stat_t{}, nil, err
	}
	data, err := readStableBounded(file, stat, limit)
	if err != nil {
		if errors.Is(err, errWitnessOutsideBound) {
			return file, stat, nil, refuse(mismatchCode, false, err)
		}
		return file, stat, nil, classifyWitnessReadFailure(err)
	}
	return file, stat, data, nil
}

func classifyBeadsOpen(err error) error {
	if _, ok := AsRefusal(err); ok {
		return err
	}
	switch {
	case errors.Is(err, unix.ENOENT), errors.Is(err, unix.ENOTDIR):
		return refuse(CodeSourceLayoutMissing, false, err)
	case errors.Is(err, unix.ELOOP):
		return refuse(CodeUnsafeSourceSymlink, false, err)
	case errors.Is(err, unix.EXDEV):
		return refuse(CodeCrossDeviceSource, false, err)
	default:
		return refuse(CodeSourceUnverifiable, true, err)
	}
}

func rejectRollbackCollision(project *os.File) error {
	var stat unix.Stat_t
	err := unix.Fstatat(int(project.Fd()), rollbackDirectory, &stat, unix.AT_SYMLINK_NOFOLLOW)
	if err == nil {
		return refuse(CodeRollbackCollision, false, nil)
	}
	if errors.Is(err, unix.ENOENT) {
		return nil
	}
	return refuse(CodeSourceUnverifiable, true, err)
}

func readStableBounded(file *os.File, expected unix.Stat_t, limit int64) ([]byte, error) {
	if expected.Size < 0 || expected.Size > limit {
		var after unix.Stat_t
		if err := unix.Fstat(int(file.Fd()), &after); err != nil {
			return nil, err
		}
		if !sameStat(expected, after) {
			return nil, errWitnessChanged
		}
		return nil, errWitnessOutsideBound
	}
	data, err := io.ReadAll(io.NewSectionReader(file, 0, limit+1))
	if err != nil {
		return nil, err
	}
	var after unix.Stat_t
	if err := unix.Fstat(int(file.Fd()), &after); err != nil {
		return nil, err
	}
	if !sameStat(expected, after) || int64(len(data)) != after.Size {
		return nil, errWitnessChanged
	}
	if int64(len(data)) > limit {
		return nil, errWitnessOutsideBound
	}
	return data, nil
}

func classifyWitnessReadFailure(err error) error {
	if errors.Is(err, errWitnessChanged) {
		return refuse(CodeSourceChanged, true, err)
	}
	return refuse(CodeSourceUnverifiable, true, err)
}

func parseMetadata(data []byte) (metadataShape, error) {
	values, err := decodeUniqueObject(data)
	if err != nil {
		return metadataShape{}, err
	}
	database, projectID, err := requiredMetadataShape(values)
	if err != nil {
		return metadataShape{}, err
	}
	if err := rejectDisallowedMetadataFields(values); err != nil {
		return metadataShape{}, err
	}
	return metadataShape{database: database, projectID: projectID}, nil
}

// requiredMetadataShape enforces the exact scalar contract of a v0.62 local
// Dolt-server metadata document and returns the validated dolt database name
// and project id.
func requiredMetadataShape(values map[string]json.RawMessage) (string, string, error) {
	for _, field := range []struct{ key, want string }{
		{"backend", "dolt"},
		{"database", "dolt"},
		{"dolt_mode", "server"},
	} {
		if got, ok := requiredString(values, field.key); !ok || got != field.want {
			return "", "", errors.New(field.key)
		}
	}
	if _, present := values["dolt_server_host"]; present {
		if host, ok := requiredString(values, "dolt_server_host"); !ok || host != "127.0.0.1" {
			return "", "", errors.New("dolt_server_host")
		}
	}
	database, ok := requiredString(values, "dolt_database")
	if !ok || !databaseNamePattern.MatchString(database) {
		return "", "", errors.New("dolt_database")
	}
	projectID, ok := requiredString(values, "project_id")
	if !ok || !projectIDPattern.MatchString(projectID) {
		return "", "", errors.New("project_id")
	}
	if _, present := values["dolt_server_port"]; present {
		if port, ok := requiredInteger(values, "dolt_server_port"); !ok || port < 1 || port > 65535 {
			return "", "", errors.New("dolt_server_port")
		}
	}
	return database, projectID, nil
}

// rejectDisallowedMetadataFields fails closed on any field outside the allowed
// v0.62 set, any foreign-provider metadata, and any non-empty custom data dir.
func rejectDisallowedMetadataFields(values map[string]json.RawMessage) error {
	for key, raw := range values {
		if _, allowed := allowedV062MetadataFields[key]; !allowed {
			return errors.New("unknown v0.62 metadata field")
		}
		lower := strings.ToLower(key)
		if strings.HasPrefix(lower, "postgres") || strings.HasPrefix(lower, "mysql") ||
			strings.HasPrefix(lower, "sqlite") || strings.HasPrefix(lower, "proxied") {
			return errors.New("foreign provider metadata")
		}
		if key == "dolt_data_dir" {
			var value string
			if err := json.Unmarshal(raw, &value); err != nil || value != "" {
				return errors.New("custom server path")
			}
		}
	}
	return nil
}

func decodeUniqueObject(data []byte) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New("metadata is not an object")
	}
	values := make(map[string]json.RawMessage)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		key, ok := token.(string)
		if !ok {
			return nil, errors.New("metadata key is not a string")
		}
		if _, duplicate := values[key]; duplicate {
			return nil, errors.New("duplicate metadata key")
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, err
		}
		values[key] = raw
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, errors.New("unterminated metadata object")
	}
	if token, err = decoder.Token(); !errors.Is(err, io.EOF) || token != nil {
		return nil, errors.New("trailing metadata content")
	}
	return values, nil
}

func requiredString(values map[string]json.RawMessage, key string) (string, bool) {
	raw, ok := values[key]
	if !ok {
		return "", false
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", false
	}
	return value, true
}

func requiredInteger(values map[string]json.RawMessage, key string) (int64, bool) {
	raw, ok := values[key]
	if !ok {
		return 0, false
	}
	value, err := strconv.ParseInt(string(raw), 10, 64)
	return value, err == nil
}

func (fs sourceFS) inspectTree(root *os.File, rootStat unix.Stat_t, includeContent bool) (treeSnapshot, error) {
	rootCopy, opened, err := fs.openDirectoryAt(root, ".")
	if err != nil {
		return treeSnapshot{}, classifyTreeOpen(err)
	}
	if !sameStat(rootStat, opened) {
		_ = rootCopy.Close()
		return treeSnapshot{}, refuse(CodeSourceChanged, true, nil)
	}
	treeHash := sha256.New()
	structureHash := sha256.New()
	kinds := make(map[string]byte)
	writeTreeRecord(treeHash, 'd', ".", opened, nil)
	writeStructureRecord(structureHash, 'd', ".", opened)
	inspectErr := fs.inspectDirectory(rootCopy, "", includeContent, treeHash, structureHash, kinds)
	closeErr := rootCopy.Close()
	if inspectErr != nil {
		return treeSnapshot{}, inspectErr
	}
	if closeErr != nil {
		return treeSnapshot{}, refuse(CodeSourceUnverifiable, true, closeErr)
	}
	return treeSnapshot{
		treeSHA256:      hex.EncodeToString(treeHash.Sum(nil)),
		structureSHA256: hex.EncodeToString(structureHash.Sum(nil)),
		kinds:           kinds,
	}, nil
}

func (fs sourceFS) inspectDirectory(dir *os.File, relative string, includeContent bool, treeHash, structureHash hash.Hash, kinds map[string]byte) error {
	names, err := dir.Readdirnames(-1)
	if err != nil {
		return refuse(CodeSourceUnverifiable, true, err)
	}
	sort.Strings(names)
	for _, name := range names {
		path := joinRelative(relative, name)
		named, err := fs.statTreeEntry(dir, name)
		if err != nil {
			return err
		}
		switch named.Mode & unix.S_IFMT {
		case unix.S_IFLNK:
			return refuse(CodeUnsafeSourceSymlink, false, nil)
		case unix.S_IFDIR:
			if err := fs.inspectSubdirectory(dir, name, path, includeContent, treeHash, structureHash, kinds); err != nil {
				return err
			}
		case unix.S_IFREG:
			if err := fs.hashRegularTreeEntry(dir, name, path, named, includeContent, treeHash, structureHash, kinds); err != nil {
				return err
			}
		default:
			return refuse(CodeUnsafeSourceObject, false, nil)
		}
	}
	return nil
}

func joinRelative(relative, name string) string {
	if relative == "" {
		return name
	}
	return relative + "/" + name
}

// statTreeEntry stats a directory entry without following symlinks and binds it
// to the retained source device and mount before the caller inspects its kind.
func (fs sourceFS) statTreeEntry(dir *os.File, name string) (unix.Stat_t, error) {
	var named unix.Stat_t
	if err := unix.Fstatat(int(dir.Fd()), name, &named, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ESTALE) {
			return unix.Stat_t{}, refuse(CodeSourceChanged, true, err)
		}
		return unix.Stat_t{}, refuse(CodeSourceUnverifiable, true, err)
	}
	if err := checkDevice(named.Dev, fs.device); err != nil {
		return unix.Stat_t{}, err
	}
	if err := fs.checkMountAt(int(dir.Fd()), name, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return unix.Stat_t{}, err
	}
	return named, nil
}

func (fs sourceFS) inspectSubdirectory(dir *os.File, name, path string, includeContent bool, treeHash, structureHash hash.Hash, kinds map[string]byte) error {
	child, opened, err := fs.openDirectoryAt(dir, name)
	if err != nil {
		return classifyTreeOpen(err)
	}
	kinds[path] = 'd'
	writeTreeRecord(treeHash, 'd', path, opened, nil)
	writeStructureRecord(structureHash, 'd', path, opened)
	err = fs.inspectDirectory(child, path, includeContent, treeHash, structureHash, kinds)
	closeErr := child.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return refuse(CodeSourceUnverifiable, true, closeErr)
	}
	return nil
}

// hashRegularTreeEntry opens a regular tree file under its retained descriptor,
// folds its content and structure into the running digests, and re-stats it to
// prove it did not change during the read.
func (fs sourceFS) hashRegularTreeEntry(dir *os.File, name, path string, named unix.Stat_t, includeContent bool, treeHash, structureHash hash.Hash, kinds map[string]byte) error {
	if named.Nlink != 1 {
		return refuse(CodeUnsafeSourceHardlink, false, nil)
	}
	file, opened, err := fs.openRegularTreeFile(dir, name, named)
	if err != nil {
		return err
	}
	var contentDigest []byte
	if includeContent {
		contentHash := sha256.New()
		if _, err := io.Copy(contentHash, file); err != nil {
			_ = file.Close()
			return refuse(CodeSourceUnverifiable, true, err)
		}
		contentDigest = contentHash.Sum(nil)
	}
	var after unix.Stat_t
	statErr := unix.Fstat(int(file.Fd()), &after)
	closeErr := file.Close()
	if statErr != nil {
		return refuse(CodeSourceUnverifiable, true, statErr)
	}
	if !sameStat(opened, after) {
		return refuse(CodeSourceChanged, true, nil)
	}
	if closeErr != nil {
		return refuse(CodeSourceUnverifiable, true, closeErr)
	}
	kinds[path] = 'f'
	if includeContent {
		writeTreeRecord(treeHash, 'f', path, opened, contentDigest)
	}
	writeStructureRecord(structureHash, 'f', path, opened)
	return nil
}

func (fs sourceFS) openRegularTreeFile(parent *os.File, name string, named unix.Stat_t) (*os.File, unix.Stat_t, error) {
	fd, err := unix.Openat(int(parent.Fd()), name, regularFileOpenFlags, 0)
	if err != nil {
		return nil, unix.Stat_t{}, classifyTreeOpen(err)
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		_ = unix.Close(fd)
		return nil, unix.Stat_t{}, refuse(CodeSourceUnverifiable, true, nil)
	}
	var opened unix.Stat_t
	if err := unix.Fstat(fd, &opened); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, refuse(CodeSourceUnverifiable, true, err)
	}
	if err := checkDevice(opened.Dev, fs.device); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, err
	}
	if err := fs.checkMountAt(fd, "", unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW); err != nil {
		_ = file.Close()
		return nil, unix.Stat_t{}, err
	}
	if opened.Mode&unix.S_IFMT != unix.S_IFREG || opened.Nlink != 1 {
		_ = file.Close()
		return nil, unix.Stat_t{}, refuse(CodeUnsafeSourceObject, false, nil)
	}
	if !sameStat(named, opened) {
		_ = file.Close()
		return nil, unix.Stat_t{}, refuse(CodeSourceChanged, true, nil)
	}
	return file, opened, nil
}

func classifyTreeOpen(err error) error {
	if _, ok := AsRefusal(err); ok {
		return err
	}
	switch {
	case errors.Is(err, unix.ELOOP):
		return refuse(CodeUnsafeSourceSymlink, false, err)
	case errors.Is(err, unix.EXDEV):
		return refuse(CodeCrossDeviceSource, false, err)
	case errors.Is(err, unix.ENOENT), errors.Is(err, unix.ESTALE):
		return refuse(CodeSourceChanged, true, err)
	default:
		return refuse(CodeSourceUnverifiable, true, err)
	}
}

func checkDevice(actual, expected uint64) error {
	if actual != expected {
		return refuse(CodeCrossDeviceSource, false, nil)
	}
	return nil
}

func validateRequiredLayout(kinds map[string]byte, database string) error {
	for _, routingArtifact := range []string{".env", "redirect"} {
		if _, exists := kinds[routingArtifact]; exists {
			return refuse(CodeSourceRoutingUnsupported, false, nil)
		}
	}
	for _, mixed := range []string{"embeddeddolt", "beads.db", "proxieddb", "sqlite.db"} {
		if _, exists := kinds[mixed]; exists {
			return refuse(CodeMixedStorageLayout, false, nil)
		}
	}
	for path, kind := range kinds {
		if kind == 'f' && isRootSQLiteArtifact(path) {
			return refuse(CodeMixedStorageLayout, false, nil)
		}
		parts := strings.Split(path, "/")
		if kind == 'd' && len(parts) == 3 && parts[0] == "dolt" && parts[2] == ".dolt" && parts[1] != database {
			// An immediate dolt/<name>/.dolt is another database root. Nested
			// stats repositories such as dolt/.dolt/stats/.dolt and
			// dolt/<database>/.dolt/stats/.dolt are authentic Dolt layout.
			return refuse(CodeMixedStorageLayout, false, nil)
		}
	}
	required := map[string]byte{
		".local_version":                              'f',
		"metadata.json":                               'f',
		"dolt":                                        'd',
		"dolt/config.yaml":                            'f',
		"dolt/.dolt":                                  'd',
		"dolt/.dolt/config.json":                      'f',
		"dolt/.dolt/repo_state.json":                  'f',
		"dolt/" + database:                            'd',
		"dolt/" + database + "/.dolt":                 'd',
		"dolt/" + database + "/.dolt/config.json":     'f',
		"dolt/" + database + "/.dolt/repo_state.json": 'f',
	}
	for path, kind := range required {
		if kinds[path] != kind {
			return refuse(CodeSourceLayoutMissing, false, nil)
		}
	}
	return nil
}

func isRootSQLiteArtifact(path string) bool {
	if strings.Contains(path, "/") {
		return false
	}
	name := strings.ToLower(path)
	for _, ancillary := range []string{
		"ephemeral.sqlite3",
		"ephemeral.sqlite3-journal",
		"ephemeral.sqlite3-wal",
		"ephemeral.sqlite3-shm",
	} {
		if name == ancillary {
			return false
		}
	}
	for _, suffix := range []string{
		".db", ".db-journal", ".db-wal", ".db-shm",
		".sqlite", ".sqlite-journal", ".sqlite-wal", ".sqlite-shm",
		".sqlite3", ".sqlite3-journal", ".sqlite3-wal", ".sqlite3-shm",
	} {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return strings.Contains(name, ".db?")
}

func (fs sourceFS) revalidateSource(projectPath string, project *os.File, projectStat unix.Stat_t, beads *os.File, beadsStat unix.Stat_t, version *os.File, versionStat unix.Stat_t, metadata *os.File, metadataStat unix.Stat_t, expectedVersion, expectedMetadata []byte) error {
	for _, item := range []struct {
		file *os.File
		want unix.Stat_t
	}{
		{project, projectStat},
		{beads, beadsStat},
		{version, versionStat},
		{metadata, metadataStat},
	} {
		var current unix.Stat_t
		if err := unix.Fstat(int(item.file.Fd()), &current); err != nil {
			return refuse(CodeSourceUnverifiable, true, err)
		}
		if !sameStat(item.want, current) {
			return refuse(CodeSourceChanged, true, nil)
		}
		if err := checkDevice(current.Dev, fs.device); err != nil {
			return err
		}
		if err := fs.checkMountAt(int(item.file.Fd()), "", unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return err
		}
	}
	if err := fs.entryStillNames(project, ".beads", beadsStat); err != nil {
		return err
	}
	if err := fs.entryStillNames(beads, ".local_version", versionStat); err != nil {
		return err
	}
	if err := fs.entryStillNames(beads, "metadata.json", metadataStat); err != nil {
		return err
	}
	versionBytes, err := readStableBounded(version, versionStat, maxVersionBytes)
	if err != nil {
		return classifyWitnessReadFailure(err)
	}
	if !bytes.Equal(versionBytes, expectedVersion) {
		return refuse(CodeSourceChanged, true, nil)
	}
	metadataBytes, err := readStableBounded(metadata, metadataStat, maxMetadataBytes)
	if err != nil {
		return classifyWitnessReadFailure(err)
	}
	if !bytes.Equal(metadataBytes, expectedMetadata) {
		return refuse(CodeSourceChanged, true, nil)
	}
	canonical, err := os.Readlink(fmt.Sprintf("/proc/self/fd/%d", project.Fd()))
	if err != nil {
		return refuse(CodeSourceUnverifiable, true, err)
	}
	if canonical != projectPath {
		return refuse(CodeSourceChanged, true, nil)
	}
	return fs.reverifyProjectIdentity(projectPath, projectStat)
}

// reverifyProjectIdentity reopens the canonical project path and proves the
// fresh descriptor still names the same inode on the same source mount, closing
// the residual window between the retained descriptor and a path-based reopen.
func (fs sourceFS) reverifyProjectIdentity(projectPath string, projectStat unix.Stat_t) error {
	reopened, reopenedStat, reopenedMountID, err := openProject(projectPath, fs.readMountID)
	if err != nil {
		if refusal, ok := AsRefusal(err); ok && refusal.Code == CodeSourceUnverifiable {
			return err
		}
		return refuse(CodeSourceChanged, true, err)
	}
	closeErr := reopened.Close()
	if !sameStat(projectStat, reopenedStat) {
		return refuse(CodeSourceChanged, true, nil)
	}
	if err := checkMountID(reopenedMountID, fs.mountID); err != nil {
		return err
	}
	if closeErr != nil {
		return refuse(CodeSourceUnverifiable, true, closeErr)
	}
	return nil
}

func (fs sourceFS) entryStillNames(parent *os.File, name string, expected unix.Stat_t) error {
	var current unix.Stat_t
	if err := unix.Fstatat(int(parent.Fd()), name, &current, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ESTALE) {
			return refuse(CodeSourceChanged, true, err)
		}
		return refuse(CodeSourceUnverifiable, true, err)
	}
	if !sameStat(expected, current) {
		return refuse(CodeSourceChanged, true, nil)
	}
	if err := checkDevice(current.Dev, fs.device); err != nil {
		return err
	}
	if err := fs.checkMountAt(int(parent.Fd()), name, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	return nil
}

func sameStat(left, right unix.Stat_t) bool {
	return left.Dev == right.Dev && left.Ino == right.Ino && left.Mode == right.Mode &&
		left.Nlink == right.Nlink && left.Rdev == right.Rdev && left.Size == right.Size &&
		left.Mtim == right.Mtim && left.Ctim == right.Ctim
}

func writeTreeRecord(writer hash.Hash, kind byte, path string, stat unix.Stat_t, contentDigest []byte) {
	writeField(writer, []byte{kind})
	writeField(writer, []byte(path))
	var numeric [16]byte
	binary.BigEndian.PutUint64(numeric[:8], uint64(stat.Mode&0o7777))
	if kind == 'f' {
		binary.BigEndian.PutUint64(numeric[8:], uint64(stat.Size))
	}
	writeField(writer, numeric[:])
	writeField(writer, contentDigest)
}

func writeStructureRecord(writer hash.Hash, kind byte, path string, stat unix.Stat_t) {
	writeField(writer, []byte{kind})
	writeField(writer, []byte(path))
	values := []uint64{
		stat.Dev, stat.Ino, uint64(stat.Mode), stat.Nlink, stat.Rdev, uint64(stat.Size),
		uint64(stat.Mtim.Sec), uint64(stat.Mtim.Nsec), uint64(stat.Ctim.Sec), uint64(stat.Ctim.Nsec),
	}
	var numeric [8]byte
	for _, value := range values {
		binary.BigEndian.PutUint64(numeric[:], value)
		writeField(writer, numeric[:])
	}
}

func writeField(writer hash.Hash, value []byte) {
	var size [8]byte
	binary.BigEndian.PutUint64(size[:], uint64(len(value)))
	_, _ = writer.Write(size[:])
	_, _ = writer.Write(value)
}

func closeForInspection(result *Result, returnErr *error, file *os.File) {
	if file == nil {
		return
	}
	if err := file.Close(); err != nil {
		*result = Result{}
		*returnErr = refuse(CodeSourceUnverifiable, true, err)
	}
}
