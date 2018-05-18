/**
 * Getting currently mounted volumes and information about them in crossplatform way.
 * Authors:
 *  $(LINK2 https://github.com/FreeSlave, Roman Chistokhodov)
 * Copyright:
 *  Roman Chistokhodov, 2018
 * License:
 *  $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */
module volumeinfo;

import std.typecons : RefCounted;

version(OSX) {} else version(Posix)
{
    private @safe bool isSpecialFileSystem(const(char)[] dir, const(char)[] type)
    {
        import std.string : startsWith;
        if (dir.startsWith("/dev") || dir.startsWith("/proc") || dir.startsWith("/sys") ||
            dir.startsWith("/var/run") || dir.startsWith("/var/lock"))
        {
            return true;
        }

        if (type == "tmpfs" || type == "rootfs" || type == "rpc_pipefs") {
            return true;
        }
        return false;
    }
}

version(FreeBSD)
{
private:
    import core.sys.posix.sys.types;

    enum MFSNAMELEN = 16;          /* length of type name including null */
    enum MNAMELEN  = 88;          /* size of on/from name bufs */
    enum STATFS_VERSION = 0x20030518;      /* current version number */

    struct fsid_t
    {
        int[2] val;
    }

    struct statfs_t {
        uint f_version;         /* structure version number */
        uint f_type;            /* type of filesystem */
        ulong f_flags;           /* copy of mount exported flags */
        ulong f_bsize;           /* filesystem fragment size */
        ulong f_iosize;          /* optimal transfer block size */
        ulong f_blocks;          /* total data blocks in filesystem */
        ulong f_bfree;           /* free blocks in filesystem */
        long  f_bavail;          /* free blocks avail to non-superuser */
        ulong f_files;           /* total file nodes in filesystem */
        long  f_ffree;           /* free nodes avail to non-superuser */
        ulong f_syncwrites;      /* count of sync writes since mount */
        ulong f_asyncwrites;         /* count of async writes since mount */
        ulong f_syncreads;       /* count of sync reads since mount */
        ulong f_asyncreads;      /* count of async reads since mount */
        ulong[10] f_spare;       /* unused spare */
        uint f_namemax;         /* maximum filename length */
        uid_t     f_owner;          /* user that mounted the filesystem */
        fsid_t    f_fsid;           /* filesystem id */
        char[80]      f_charspare;      /* spare string space */
        char[MFSNAMELEN] f_fstypename; /* filesystem type name */
        char[MNAMELEN] f_mntfromname;  /* mounted filesystem */
        char[MNAMELEN] f_mntonname;    /* directory on which mounted */
    };

    extern(C) @nogc nothrow
    {
        int getmntinfo(statfs_t **mntbufp, int flags);
        int statfs(const char *path, statfs_t *buf);
    }

    @trusted bool parseStatfs(ref const(statfs_t)* buf, out const(char)[] device, out const(char)[] mountDir, out const(char)[] type) nothrow {
        assert(buf);
        import std.string : fromStringz;
        auto type = fromStringz(buf.f_fstypename.ptr);
        auto device = fromStringz(buf.f_mntfromname.ptr);
        auto mountDir = fromStringz(buf.f_mntonname.ptr);
        return true;
    }
}

version(CRuntime_Glibc)
{
private:
    import core.stdc.stdio : FILE;
    struct mntent
    {
        char *mnt_fsname;   /* Device or server for filesystem.  */
        char *mnt_dir;      /* Directory mounted on.  */
        char *mnt_type;     /* Type of filesystem: ufs, nfs, etc.  */
        char *mnt_opts;     /* Comma-separated options for fs.  */
        int mnt_freq;       /* Dump frequency (in days).  */
        int mnt_passno;     /* Pass number for `fsck'.  */
    };

    extern(C) @nogc nothrow
    {
        FILE *setmntent(const char *file, const char *mode);
        mntent *getmntent(FILE *stream);
        mntent *getmntent_r(FILE * stream, mntent *result, char * buffer, int bufsize);
        int addmntent(FILE* stream, const mntent *mnt);
        int endmntent(FILE * stream);
        char *hasmntopt(const mntent *mnt, const char *opt);
    }

    @safe string unescapeLabel(string label)
    {
        import std.string : replace;
        return label.replace("\\x20", " ")
                    .replace("\\x9", "\t")
                    .replace("\\x5c", "\\")
                    .replace("\\xA", "\n");
    }

    @trusted string retrieveLabel(string fsName) nothrow {
        import std.file : dirEntries, SpanMode, readLink;
        import std.path : buildNormalizedPath, isAbsolute, baseName;
        import std.exception : collectException;
        enum byLabel = "/dev/disk/by-label";
        if (fsName.isAbsolute) { // /dev/sd*
            try {
                foreach(entry; dirEntries(byLabel, SpanMode.shallow))
                {
                    string resolvedLink;
                    if (entry.isSymlink && collectException(entry.readLink, resolvedLink) is null) {
                        auto normalized = buildNormalizedPath(byLabel, resolvedLink);
                        if (normalized == fsName)
                            return entry.name.baseName.unescapeLabel();
                    }
                }
            } catch(Exception e) {

            }
        }
        return string.init;
    }

    @trusted bool parseMntent(ref const mntent ent, out const(char)[] device, out const(char)[] mountDir, out const(char)[] type) nothrow {
        import std.string : fromStringz;
        device = fromStringz(ent.mnt_fsname);
        mountDir = fromStringz(ent.mnt_dir);
        type = fromStringz(ent.mnt_type);
        return true;
    }
    @trusted bool parseMountsLine(const(char)[] line, out const(char)[] device, out const(char)[] mountDir, out const(char)[] type) nothrow {
        import std.algorithm.iteration : splitter;
        import std.string : representation;
        auto splitted = splitter(line.representation, ' ');
        if (!splitted.empty) {
            device = cast(const(char)[])splitted.front;
            splitted.popFront();
            if (!splitted.empty) {
                mountDir = cast(const(char)[])splitted.front;
                splitted.popFront();
                if (!splitted.empty) {
                    type = cast(const(char)[])splitted.front;
                    return true;
                }
            }
        }
        return false;
    }
}

/**
 * Get mountpoint where the provided path resides on.
 */
@trusted string volumePath(string path)
{
    if (path.length == 0)
        return string.init;
    import std.path : absolutePath;
    path = path.absolutePath;
    version(Posix) {
        import core.sys.posix.sys.types;
        import core.sys.posix.sys.stat;
        import core.sys.posix.unistd;
        import core.sys.posix.fcntl;
        import std.path : dirName;
        import std.string : toStringz;

        auto current = path;
        stat_t currentStat;
        if (stat(current.toStringz, &currentStat) != 0) {
            return null;
        }
        stat_t parentStat;
        while(current != "/") {
            string parent = current.dirName;
            if (lstat(parent.toStringz, &parentStat) != 0) {
                return null;
            }
            if (currentStat.st_dev != parentStat.st_dev) {
                return current;
            }
            current = parent;
        }
        return current;
    } else {
        return string.init;
    }
}

version(Posix) private struct VolumeInfoImpl
{
    @safe this(string path) nothrow {
        import std.path : isAbsolute;
        assert(path.isAbsolute);
        this.path = path;
    }
    @safe this(string mountPoint, string device, string type) nothrow {
        path = mountPoint;
        _device = device;
        _type = type;
        if (device.length && type.length) {
            _deviceAndTypeRetrieved = true;
        }
    }
    version(FreeBSD) @safe this(string mountPoint, string device, string type, const(statfs_t)* buf) nothrow {
        assert(buf);
        this(mountPoint, device, type);
        _bytesTotal = buf.f_bsize * buf.f_blocks;
        _bytesFree = buf.f_bsize * buf.f_bfree;
        _bytesAvailable = buf.f_bsize * buf.f_bavail;
        _readOnly = (buf.f_flags & FFlag.ST_RDONLY) != 0;
        _volumeInfoRetrieved = true;
    }
    version(CRuntime_Glibc) {
        @safe @property string label() nothrow {
            if (!_labelRetrieved) {
                _label = retrieveLabel(device);
                _labelRetrieved = true;
            }
            return _label;
        }
        string _label;
        bool _labelRetrieved;
    } else {
        enum label = string.init;
    }

    bool _volumeInfoRetrieved;
    bool _deviceAndTypeRetrieved;
    bool _readOnly;

    string path;
    string _device;
    string _type;

    @safe @property string device() nothrow {
        retrieveDeviceAndType();
        return _device;
    }
    @safe @property string type() nothrow {
        retrieveDeviceAndType();
        return _type;
    }

    long _bytesTotal = -1;
    long _bytesFree = -1;
    long _bytesAvailable = -1;

    @safe @property long bytesTotal() nothrow {
        retrieveVolumeInfo();
        return _bytesTotal;
    }
    @safe @property long bytesFree() nothrow {
        retrieveVolumeInfo();
        return _bytesFree;
    }
    @safe @property long bytesAvailable() nothrow {
        retrieveVolumeInfo();
        return _bytesAvailable;
    }
    @safe @property bool readOnly() nothrow {
        retrieveVolumeInfo();
        return _readOnly;
    }

    @trusted void retrieveVolumeInfo() nothrow {
        import std.string : toStringz;
        import std.exception : assumeWontThrow;
        import core.sys.posix.sys.statvfs;

        if (_volumeInfoRetrieved || path.length == 0)
            return;
        _volumeInfoRetrieved = true;

        statvfs_t buf;
        if (assumeWontThrow(statvfs(toStringz(path), &buf)) == 0) {
            version(FreeBSD) {
                _bytesTotal = buf.f_bsize * buf.f_blocks;
                _bytesFree = buf.f_bsize * buf.f_bfree;
                _bytesAvailable = buf.f_bsize * buf.f_bavail;
            } else {
                _bytesTotal = buf.f_frsize * buf.f_blocks;
                _bytesFree = buf.f_frsize * buf.f_bfree;
                _bytesAvailable = buf.f_frsize * buf.f_bavail;
            }
            _readOnly = (buf.f_flag & FFlag.ST_RDONLY) != 0;
        }
    }

    @trusted void retrieveDeviceAndType() nothrow {
        if (_deviceAndTypeRetrieved || path.length == 0)
            return;
        _deviceAndTypeRetrieved = true;
        version(CRuntime_Glibc)
        {
            // we need to loop through all mountpoints again to find a type by path. Is there a faster way to get file system type?
            try {
                import std.stdio : File;
                foreach(line; File("/proc/self/mounts", "r").byLine) {
                    const(char)[] device, mountDir, type;
                    if (parseMountsLine(line, device, mountDir, type)) {
                        if (mountDir == path) {
                            _device = device.idup;
                            _type = type.idup;
                            break;
                        }
                    }
                }
            } catch(Exception e) {
                mntent ent;
                char[1024] buf;
                FILE* f = setmntent("/etc/mtab", "r");
                if (f is null)
                    return;
                scope(exit) endmntent(f);
                while(getmntent_r(f, &ent, buf.ptr, cast(int)buf.length) !is null) {
                    const(char)[] device, mountDir, type;
                    parseMntent(ent, device, mountDir, type);
                    if (mountDir == path) {
                        _device = device.idup;
                        _type = type.idup;
                        break;
                    }
                }
            }
        }
        else version(FreeBSD)
        {
            import std.string : toStringz;
            statfs_t buf;
            if (statfs(toStringz(path), &buf) == 0) {
                const(char)[] device, mountDir, type;
                parseStatfs(buf, device, mountDir, type);
                _device = device.idup;
                _type = type.idup;
            }
        }
    }
}

/**
 * Represents a filesystem volume. Provides information about mountpoint, filesystem type and storage size.
 */
struct VolumeInfo
{
    /**
     * Construct an object that gives information about volume on which the provided path is located.
     * Params:
     *  path = either root path of volume or any file or directory that resides on the volume.
     */
    @trusted this(string path) {
        impl = RefCounted!VolumeInfoImpl(volumePath(path));
    }
    /// Root path of file system (mountpoint of partition).
    @trusted @property string path() nothrow {
        return impl.path;
    }
    /// Device string, e.g. /dev/sda.
    @trusted @property string device() nothrow {
        return impl.device;
    }
    /**
     * File system type, e.g. ext4.
     */
    @trusted @property string type() nothrow {
        return impl.type;
    }
    /**
     * Name of volume. Empty string if volume label could not be retrieved.
     * In case the label is empty you may consider using the base name of volume path as a display name, possible in combination with type.
     */
    @trusted @property string label() nothrow {
        return impl.label;
    }
    /**
     * Total volume size.
     * Returns: total volume size in bytes or -1 if could not determine the size.
     */
    @trusted @property long bytesTotal() nothrow {
        return impl.bytesTotal;
    }
    /**
     * Free space in a volume
     * Note: This is size of free space in a volume, but actual free space available for the current user may be smaller.
     * Returns: number of free bytes in a volume or -1 if could not determine the number.
     * See_Also: $(D bytesAvailable)
     */
    @trusted @property long bytesFree() nothrow {
        return impl.bytesFree;
    }
    /**
     * Free space available for the current user.
     * This is what most tools and GUI applications show as free space.
     * Returns: number of free bytes available for the current user or -1 if could not determine the number.
     */
    @trusted @property long bytesAvailable() nothrow {
        return impl.bytesAvailable;
    }
    /// Whether the referenced filesystem is marked as readonly.
    @trusted @property bool readOnly() nothrow {
        return impl.readOnly;
    }
    @safe string toString() {
        import std.format;
        return format("VolumeInfo(%s, %s)", path, type);
    }
private:
    this(VolumeInfoImpl impl) {
        this.impl = RefCounted!VolumeInfoImpl(impl);
    }
    RefCounted!VolumeInfoImpl impl;
}

unittest
{
    VolumeInfo info;
    assert(info.path == "");
    assert(info.type == "");
    assert(info.label == "");
    assert(info.bytesTotal < 0);
    assert(info.bytesAvailable < 0);
    assert(info.bytesFree < 0);
    assert(!info.readOnly);
}

/**
 * The list of currently mounted volumes.
 */
VolumeInfo[] mountedVolumes() {
    VolumeInfo[] res;
    version(CRuntime_Glibc) {
        try {
            import std.stdio : File;

            foreach(line; File("/proc/self/mounts", "r").byLine) {
                const(char)[] device, mountDir, type;
                if (parseMountsLine(line, device, mountDir, type)) {
                    if (!isSpecialFileSystem(mountDir, type)) {
                        res ~= VolumeInfo(VolumeInfoImpl(mountDir.idup, device.idup, type.idup));
                    }
                }
            }
        } catch(Exception e) {
            res.length = 0;
            res ~= VolumeInfo(VolumeInfoImpl("/", null, null));

            mntent ent;
            char[1024] buf;
            FILE* f = setmntent("/etc/mtab", "r");
            if (f is null)
                return res;

            scope(exit) endmntent(f);
            while(getmntent_r(f, &ent, buf.ptr, cast(int)buf.length) !is null) {
                const(char)[] device, mountDir, type;
                parseMntent(ent, device, mountDir, type);

                if (mountDir == "/" || isSpecialFileSystem(mountDir, type))
                    continue;

                res ~= VolumeInfo(VolumeInfoImpl(mountDir.idup, device.idup, type.idup));
            }
        }
    }
    else version(FreeBSD) {
        import std.string : fromStringz;
        res ~= VolumeInfo(VolumeInfoImpl("/", null, null));

        statfs_t* mntbufsPtr;
        int mntbufsLen = getmntinfo(&mntbufsPtr, 0);
        if (mntbufsLen) {
            auto mntbufs = mntbufsPtr[0..mntbufsLen];

            foreach(buf; mntbufs) {
                const(char)[] device, mountDir, type;
                parseStatfs(buf, device, mountDir, type);

                if (mountDir == "/" || isSpecialFileSystem(mountDir, type))
                    continue;

                res ~= VolumeInfo(VolumeInfoImpl(mountDir.idup, device.idup, type.idup, buf));
            }
        }
    }
    else version(Posix) {
        res ~= VolumeInfo(VolumeInfoImpl("/", null, null));
    }

    version (Windows) {
        import core.sys.windows.windows;
        const uint mask = GetLogicalDrives();
        foreach(int i; 0 .. 26) {
            if (mask & (1 << i)) {
                const char letter = cast(char)('A' + i);
                string path = letter ~ ":\\";
                res ~= VolumeInfo(path);
            }
        }
    }
    return res;
}