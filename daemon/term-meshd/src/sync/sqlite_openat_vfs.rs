use std::ffi::{CStr, CString};
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use rusqlite::ffi;

static NEXT_VFS_ID: AtomicU64 = AtomicU64::new(1);

struct Context {
    directory: File,
    database: Vec<u8>,
    base: *mut ffi::sqlite3_vfs,
    prefix: Vec<u8>,
    device: u64,
    shm: Mutex<ShmState>,
}

#[derive(Default)]
struct ShmState {
    file: Option<File>,
    mappings: Vec<(*mut c_void, usize)>,
    users: Vec<usize>,
    shared_refs: [u32; 8],
    exclusive_owner: [usize; 8],
    dms_locked: bool,
}

unsafe impl Send for ShmState {}

#[repr(C)]
struct OpenFileExtra {
    retained_fd: c_int,
    original_methods: *const ffi::sqlite3_io_methods,
    wrapper_methods: *mut WrapperMethods,
    context: *const Context,
    shared_mask: u16,
    exclusive_mask: u16,
}

#[repr(C)]
struct WrapperMethods {
    methods: ffi::sqlite3_io_methods,
    extra_offset: usize,
}

pub(crate) struct OpenAtVfs {
    name: CString,
    context: Box<Context>,
    vfs: Box<ffi::sqlite3_vfs>,
}

unsafe impl Send for OpenAtVfs {}
unsafe impl Sync for OpenAtVfs {}

impl OpenAtVfs {
    pub(crate) fn register(directory: &File, database: &str) -> io::Result<Arc<Self>> {
        type Registry = std::collections::BTreeMap<(u64, u64, String), Weak<OpenAtVfs>>;
        static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
        let metadata = directory.metadata()?;
        use std::os::unix::fs::MetadataExt;
        let key = (metadata.dev(), metadata.ino(), database.to_owned());
        let registry = REGISTRY.get_or_init(|| Mutex::new(Registry::new()));
        let mut registry = registry
            .lock()
            .map_err(|_| io::Error::other("SQLite VFS registry poisoned"))?;
        if let Some(existing) = registry.get(&key).and_then(Weak::upgrade) {
            return Ok(existing);
        }
        let base = unsafe { ffi::sqlite3_vfs_find(std::ptr::null()) };
        if base.is_null() {
            return Err(io::Error::other("SQLite default VFS unavailable"));
        }
        let id = NEXT_VFS_ID.fetch_add(1, Ordering::Relaxed);
        let name = CString::new(format!("term-mesh-openat-{id}"))
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid VFS name"))?;
        let prefix = format!("/term-mesh-openat-{id}/").into_bytes();
        let mut context = Box::new(Context {
            directory: directory.try_clone()?,
            database: database.as_bytes().to_vec(),
            base,
            prefix,
            device: metadata.dev(),
            shm: Mutex::new(ShmState::default()),
        });
        let mut vfs = Box::new(unsafe { std::ptr::read(base) });
        vfs.szOsFile = extra_offset(vfs.szOsFile as usize)
            .checked_add(std::mem::size_of::<OpenFileExtra>())
            .and_then(|size| c_int::try_from(size).ok())
            .ok_or_else(|| io::Error::other("SQLite VFS file size overflow"))?;
        vfs.pNext = std::ptr::null_mut();
        vfs.zName = name.as_ptr();
        vfs.pAppData = (&mut *context as *mut Context).cast();
        vfs.xOpen = Some(open);
        vfs.xDelete = Some(delete);
        vfs.xAccess = Some(access);
        vfs.xFullPathname = Some(full_pathname);
        vfs.xDlOpen = Some(dl_open);
        vfs.xDlError = Some(dl_error);
        vfs.xDlSym = Some(dl_sym);
        vfs.xDlClose = Some(dl_close);
        vfs.xRandomness = Some(randomness);
        vfs.xSleep = Some(sleep);
        vfs.xCurrentTime = Some(current_time);
        vfs.xGetLastError = Some(last_error);
        vfs.xCurrentTimeInt64 = Some(current_time_i64);
        vfs.xSetSystemCall = Some(set_system_call);
        vfs.xGetSystemCall = Some(get_system_call);
        vfs.xNextSystemCall = Some(next_system_call);
        let result = unsafe { ffi::sqlite3_vfs_register(&mut *vfs, 0) };
        if result != ffi::SQLITE_OK {
            return Err(io::Error::other(format!(
                "SQLite VFS registration failed: {result}"
            )));
        }
        let value = Arc::new(Self { name, context, vfs });
        registry.insert(key, Arc::downgrade(&value));
        Ok(value)
    }

    pub(crate) fn name(&self) -> &str {
        self.name.to_str().unwrap_or("")
    }
}

impl Drop for OpenAtVfs {
    fn drop(&mut self) {
        unsafe {
            ffi::sqlite3_vfs_unregister(&mut *self.vfs);
        }
    }
}

unsafe fn context<'a>(vfs: *mut ffi::sqlite3_vfs) -> Option<&'a Context> {
    unsafe { vfs.as_ref() }.and_then(|value| unsafe { (value.pAppData as *const Context).as_ref() })
}

fn child_name(context: &Context, name: *const c_char) -> Option<Vec<u8>> {
    if name.is_null() {
        return None;
    }
    let bytes = unsafe { CStr::from_ptr(name) }.to_bytes();
    let child = bytes.rsplit(|byte| *byte == b'/').next()?;
    let suffix = child.strip_prefix(context.database.as_slice())?;
    if suffix.is_empty()
        || matches!(suffix, b"-wal" | b"-shm" | b"-journal")
        || suffix.starts_with(b"-mj ")
    {
        Some(child.to_vec())
    } else {
        None
    }
}

unsafe extern "C" fn open(
    vfs: *mut ffi::sqlite3_vfs,
    name: ffi::sqlite3_filename,
    file: *mut ffi::sqlite3_file,
    flags: c_int,
    out_flags: *mut c_int,
) -> c_int {
    let Some(context) = (unsafe { context(vfs) }) else {
        return ffi::SQLITE_CANTOPEN;
    };
    let Some(child) = child_name(context, name) else {
        let Some(callback) = (unsafe { context.base.as_ref() }).and_then(|base| base.xOpen) else {
            return ffi::SQLITE_CANTOPEN;
        };
        return unsafe { callback(context.base, name, file, flags, out_flags) };
    };
    let Ok(child) = CString::new(child) else {
        return ffi::SQLITE_CANTOPEN;
    };
    let mut open_flags = libc::O_CLOEXEC | libc::O_NOFOLLOW;
    open_flags |= if flags & ffi::SQLITE_OPEN_READONLY != 0 {
        libc::O_RDONLY
    } else {
        libc::O_RDWR
    };
    if flags & ffi::SQLITE_OPEN_CREATE != 0 {
        open_flags |= libc::O_CREAT;
    }
    if flags & ffi::SQLITE_OPEN_EXCLUSIVE != 0 {
        open_flags |= libc::O_EXCL;
    }
    let fd = unsafe {
        libc::openat(
            context.directory.as_raw_fd(),
            child.as_ptr(),
            open_flags,
            0o600,
        )
    };
    if fd < 0 {
        return ffi::SQLITE_CANTOPEN;
    }
    let mut stat = std::mem::MaybeUninit::uninit();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        unsafe { libc::close(fd) };
        return ffi::SQLITE_CANTOPEN;
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || stat.st_mode & 0o777 != 0o600
        || stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_nlink != 1
        || stat.st_dev as u64 != context.device
    {
        unsafe { libc::close(fd) };
        return ffi::SQLITE_CANTOPEN;
    }
    let descriptor = match CString::new(format!("/dev/fd/{fd}")) {
        Ok(value) => value,
        Err(_) => {
            unsafe { libc::close(fd) };
            return ffi::SQLITE_CANTOPEN;
        }
    };
    let Some(callback) = (unsafe { context.base.as_ref() }).and_then(|base| base.xOpen) else {
        unsafe { libc::close(fd) };
        return ffi::SQLITE_CANTOPEN;
    };
    let delegated_flags = flags
        & !(ffi::SQLITE_OPEN_CREATE | ffi::SQLITE_OPEN_EXCLUSIVE | ffi::SQLITE_OPEN_DELETEONCLOSE);
    let result = unsafe {
        callback(
            context.base,
            descriptor.as_ptr(),
            file,
            delegated_flags,
            out_flags,
        )
    };
    if result != ffi::SQLITE_OK {
        unsafe { libc::close(fd) };
        return result;
    }
    let Some(original_methods) = (unsafe { file.as_ref() }).map(|value| value.pMethods) else {
        unsafe { libc::close(fd) };
        return ffi::SQLITE_CANTOPEN;
    };
    if original_methods.is_null() {
        unsafe { libc::close(fd) };
        return ffi::SQLITE_CANTOPEN;
    }
    let offset = extra_offset(unsafe { (*context.base).szOsFile as usize });
    let mut wrapper_methods = Box::new(WrapperMethods {
        methods: unsafe { std::ptr::read(original_methods) },
        extra_offset: offset,
    });
    wrapper_methods.methods.xClose = Some(close);
    wrapper_methods.methods.xShmMap = Some(shm_map);
    wrapper_methods.methods.xShmLock = Some(shm_lock);
    wrapper_methods.methods.xShmBarrier = Some(shm_barrier);
    wrapper_methods.methods.xShmUnmap = Some(shm_unmap);
    let wrapper_methods = Box::into_raw(wrapper_methods);
    let extra = unsafe { file.cast::<u8>().add(offset) }.cast::<OpenFileExtra>();
    unsafe {
        extra.write(OpenFileExtra {
            retained_fd: fd,
            original_methods,
            wrapper_methods,
            context,
            shared_mask: 0,
            exclusive_mask: 0,
        });
        (*file).pMethods = (&(*wrapper_methods).methods) as *const _;
    }
    ffi::SQLITE_OK
}

fn extra_offset(base_size: usize) -> usize {
    let alignment = std::mem::align_of::<OpenFileExtra>();
    (base_size + alignment - 1) & !(alignment - 1)
}

unsafe extern "C" fn close(file: *mut ffi::sqlite3_file) -> c_int {
    let wrapper = unsafe { (*file).pMethods.cast::<WrapperMethods>().as_ref() };
    let Some(wrapper) = wrapper else {
        return ffi::SQLITE_IOERR_CLOSE;
    };
    let extra = unsafe { file.cast::<u8>().add(wrapper.extra_offset) }.cast::<OpenFileExtra>();
    let _ = unsafe { shm_unmap(file, 0) };
    let extra = unsafe { extra.read() };
    unsafe { (*file).pMethods = extra.original_methods };
    let result = unsafe { extra.original_methods.as_ref() }
        .and_then(|methods| methods.xClose)
        .map_or(ffi::SQLITE_IOERR_CLOSE, |callback| unsafe {
            callback(file)
        });
    if unsafe { libc::fcntl(extra.retained_fd, libc::F_GETFD) } != -1 {
        unsafe { libc::close(extra.retained_fd) };
    }
    unsafe { drop(Box::from_raw(extra.wrapper_methods)) };
    result
}

unsafe fn file_extra(file: *mut ffi::sqlite3_file) -> Option<&'static mut OpenFileExtra> {
    let wrapper = unsafe { (*file).pMethods.cast::<WrapperMethods>().as_ref() }?;
    unsafe {
        file.cast::<u8>()
            .add(wrapper.extra_offset)
            .cast::<OpenFileExtra>()
            .as_mut()
    }
}

fn open_shm(context: &Context) -> Result<File, ()> {
    let name = CString::new([context.database.as_slice(), b"-shm"].concat()).map_err(|_| ())?;
    let fd = unsafe {
        libc::openat(
            context.directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDWR | libc::O_CREAT | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    use std::os::fd::FromRawFd;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let metadata = file.metadata().map_err(|_| ())?;
    if !metadata.file_type().is_file()
        || metadata.permissions().mode() & 0o777 != 0o600
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || metadata.dev() != context.device
    {
        return Err(());
    }
    Ok(file)
}

fn set_shm_lock(
    fd: c_int,
    start: c_int,
    count: c_int,
    lock_type: impl TryInto<libc::c_short>,
) -> io::Result<()> {
    let lock_type = lock_type.try_into().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "fcntl lock type does not fit c_short",
        )
    })?;
    let mut lock = libc::flock {
        l_start: start as libc::off_t,
        l_len: count as libc::off_t,
        l_pid: 0,
        l_type: lock_type,
        l_whence: libc::SEEK_SET as libc::c_short,
    };
    if unsafe { libc::fcntl(fd, libc::F_SETLK, &mut lock) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn is_lock_busy(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(code) if code == libc::EACCES || code == libc::EAGAIN)
}

fn initialize_shm(file: &File) -> io::Result<()> {
    const DMS_BYTE: c_int = 128;
    let fd = file.as_raw_fd();
    match set_shm_lock(fd, DMS_BYTE, 1, libc::F_WRLCK) {
        Ok(()) => {
            if unsafe { libc::ftruncate(file.as_raw_fd(), 0) } != 0 {
                let error = io::Error::last_os_error();
                let _ = set_shm_lock(fd, DMS_BYTE, 1, libc::F_UNLCK);
                return Err(error);
            }
            if let Err(error) = set_shm_lock(fd, DMS_BYTE, 1, libc::F_RDLCK) {
                let _ = set_shm_lock(fd, DMS_BYTE, 1, libc::F_UNLCK);
                return Err(error);
            }
            Ok(())
        }
        Err(error) if is_lock_busy(&error) => set_shm_lock(fd, DMS_BYTE, 1, libc::F_RDLCK),
        Err(error) => Err(error),
    }
}

unsafe extern "C" fn shm_map(
    file: *mut ffi::sqlite3_file,
    page: c_int,
    page_size: c_int,
    extend: c_int,
    output: *mut *mut c_void,
) -> c_int {
    let Some(extra) = (unsafe { file_extra(file) }) else {
        return ffi::SQLITE_IOERR_SHMMAP;
    };
    let Some(context) = (unsafe { extra.context.as_ref() }) else {
        return ffi::SQLITE_IOERR_SHMMAP;
    };
    if page < 0 || page_size <= 0 || output.is_null() {
        return ffi::SQLITE_IOERR_SHMMAP;
    }
    let Ok(mut state) = context.shm.lock() else {
        return ffi::SQLITE_IOERR_SHMMAP;
    };
    if state.file.is_none() {
        match open_shm(context) {
            Ok(value) => {
                if initialize_shm(&value).is_err() {
                    return ffi::SQLITE_IOERR_SHMOPEN;
                }
                state.dms_locked = true;
                state.file = Some(value);
            }
            Err(()) => return ffi::SQLITE_IOERR_SHMOPEN,
        }
    }
    let user = file as usize;
    if !state.users.contains(&user) {
        state.users.push(user);
    }
    let page = page as usize;
    while state.mappings.len() <= page {
        state.mappings.push((std::ptr::null_mut(), 0));
    }
    if state.mappings[page].0.is_null() {
        let required = match (page + 1).checked_mul(page_size as usize) {
            Some(value) => value,
            None => return ffi::SQLITE_IOERR_SHMSIZE,
        };
        let shm = state.file.as_ref().map(AsRawFd::as_raw_fd).unwrap_or(-1);
        let mut stat = std::mem::MaybeUninit::uninit();
        if unsafe { libc::fstat(shm, stat.as_mut_ptr()) } != 0 {
            return ffi::SQLITE_IOERR_SHMSIZE;
        }
        if unsafe { stat.assume_init() }.st_size < required as libc::off_t {
            if extend == 0 {
                unsafe { *output = std::ptr::null_mut() };
                return ffi::SQLITE_OK;
            }
            if unsafe { libc::ftruncate(shm, required as libc::off_t) } != 0 {
                return ffi::SQLITE_IOERR_SHMSIZE;
            }
        }
        let mapping = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                page_size as usize,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                shm,
                (page * page_size as usize) as libc::off_t,
            )
        };
        if mapping == libc::MAP_FAILED {
            return ffi::SQLITE_IOERR_SHMMAP;
        }
        state.mappings[page] = (mapping, page_size as usize);
    }
    unsafe { *output = state.mappings[page].0 };
    ffi::SQLITE_OK
}

unsafe extern "C" fn shm_lock(
    file: *mut ffi::sqlite3_file,
    offset: c_int,
    count: c_int,
    flags: c_int,
) -> c_int {
    let Some(extra) = (unsafe { file_extra(file) }) else {
        return ffi::SQLITE_IOERR_SHMLOCK;
    };
    let Some(context) = (unsafe { extra.context.as_ref() }) else {
        return ffi::SQLITE_IOERR_SHMLOCK;
    };
    if offset < 0 || count <= 0 || offset.checked_add(count).is_none_or(|end| end > 8) {
        return ffi::SQLITE_IOERR_SHMLOCK;
    }
    let Ok(mut state) = context.shm.lock() else {
        return ffi::SQLITE_IOERR_SHMLOCK;
    };
    let Some(shm_fd) = state.file.as_ref().map(AsRawFd::as_raw_fd) else {
        return ffi::SQLITE_IOERR_SHMLOCK;
    };
    let owner = file as usize;
    let mask = (((1u16 << count) - 1) << offset) as u16;
    let lock = flags & ffi::SQLITE_SHM_LOCK != 0;
    let unlock = flags & ffi::SQLITE_SHM_UNLOCK != 0;
    let shared = flags & ffi::SQLITE_SHM_SHARED != 0;
    let exclusive = flags & ffi::SQLITE_SHM_EXCLUSIVE != 0;
    if lock == unlock || shared == exclusive {
        return ffi::SQLITE_IOERR_SHMLOCK;
    }

    if lock && shared {
        if count != 1 || state.exclusive_owner[offset as usize] != 0 {
            return ffi::SQLITE_BUSY;
        }
        if extra.shared_mask & mask != 0 {
            return ffi::SQLITE_OK;
        }
        if state.shared_refs[offset as usize] == 0 {
            if let Err(error) = set_shm_lock(shm_fd, 120 + offset, 1, libc::F_RDLCK) {
                return if is_lock_busy(&error) {
                    ffi::SQLITE_BUSY
                } else {
                    ffi::SQLITE_IOERR_SHMLOCK
                };
            }
        }
        state.shared_refs[offset as usize] += 1;
        extra.shared_mask |= mask;
        return ffi::SQLITE_OK;
    }

    if lock && exclusive {
        for slot in offset as usize..(offset + count) as usize {
            if state.shared_refs[slot] != 0 || state.exclusive_owner[slot] != 0 {
                return ffi::SQLITE_BUSY;
            }
        }
        if let Err(error) = set_shm_lock(shm_fd, 120 + offset, count, libc::F_WRLCK) {
            return if is_lock_busy(&error) {
                ffi::SQLITE_BUSY
            } else {
                ffi::SQLITE_IOERR_SHMLOCK
            };
        }
        for slot in offset as usize..(offset + count) as usize {
            state.exclusive_owner[slot] = owner;
        }
        extra.exclusive_mask |= mask;
        return ffi::SQLITE_OK;
    }

    if unlock && shared {
        for slot in offset as usize..(offset + count) as usize {
            let bit = 1u16 << slot;
            if extra.shared_mask & bit == 0 {
                continue;
            }
            state.shared_refs[slot] = state.shared_refs[slot].saturating_sub(1);
            extra.shared_mask &= !bit;
            if state.shared_refs[slot] == 0
                && set_shm_lock(shm_fd, 120 + slot as c_int, 1, libc::F_UNLCK).is_err()
            {
                return ffi::SQLITE_IOERR_SHMLOCK;
            }
        }
        return ffi::SQLITE_OK;
    }

    if extra.exclusive_mask & mask != mask {
        return ffi::SQLITE_OK;
    }
    for slot in offset as usize..(offset + count) as usize {
        let bit = 1u16 << slot;
        if extra.exclusive_mask & bit != 0 && state.exclusive_owner[slot] == owner {
            state.exclusive_owner[slot] = 0;
            extra.exclusive_mask &= !bit;
        }
    }
    if set_shm_lock(shm_fd, 120 + offset, count, libc::F_UNLCK).is_ok() {
        ffi::SQLITE_OK
    } else {
        ffi::SQLITE_IOERR_SHMLOCK
    }
}

unsafe extern "C" fn shm_barrier(_: *mut ffi::sqlite3_file) {
    std::sync::atomic::fence(Ordering::SeqCst);
}

unsafe extern "C" fn shm_unmap(file: *mut ffi::sqlite3_file, delete_file: c_int) -> c_int {
    let Some(extra) = (unsafe { file_extra(file) }) else {
        return ffi::SQLITE_IOERR_SHMMAP;
    };
    let Some(context) = (unsafe { extra.context.as_ref() }) else {
        return ffi::SQLITE_IOERR_SHMMAP;
    };
    let Ok(mut state) = context.shm.lock() else {
        return ffi::SQLITE_IOERR_SHMMAP;
    };
    let owner = file as usize;
    if let Some(shm_fd) = state.file.as_ref().map(AsRawFd::as_raw_fd) {
        for slot in 0..8 {
            let bit = 1u16 << slot;
            if extra.shared_mask & bit != 0 {
                state.shared_refs[slot] = state.shared_refs[slot].saturating_sub(1);
                if state.shared_refs[slot] == 0 {
                    let _ = set_shm_lock(shm_fd, 120 + slot as c_int, 1, libc::F_UNLCK);
                }
                extra.shared_mask &= !bit;
            }
            if extra.exclusive_mask & bit != 0 && state.exclusive_owner[slot] == owner {
                state.exclusive_owner[slot] = 0;
                let _ = set_shm_lock(shm_fd, 120 + slot as c_int, 1, libc::F_UNLCK);
                extra.exclusive_mask &= !bit;
            }
        }
    }
    state.users.retain(|user| *user != file as usize);
    if state.users.is_empty() {
        let mappings = std::mem::take(&mut state.mappings);
        if state.dms_locked {
            if let Some(shm) = state.file.as_ref() {
                let _ = set_shm_lock(shm.as_raw_fd(), 128, 1, libc::F_UNLCK);
            }
            state.dms_locked = false;
        }
        state.file = None;
        drop(state);
        for (mapping, length) in mappings {
            if !mapping.is_null() {
                unsafe { libc::munmap(mapping, length) };
            }
        }
        if delete_file != 0 {
            let Ok(name) = CString::new([context.database.as_slice(), b"-shm"].concat()) else {
                return ffi::SQLITE_IOERR_SHMMAP;
            };
            if unsafe { libc::unlinkat(context.directory.as_raw_fd(), name.as_ptr(), 0) } != 0
                && io::Error::last_os_error().kind() != io::ErrorKind::NotFound
            {
                return ffi::SQLITE_IOERR_SHMMAP;
            }
            if context.directory.sync_all().is_err() {
                return ffi::SQLITE_IOERR_DIR_FSYNC;
            }
        }
    }
    ffi::SQLITE_OK
}

unsafe extern "C" fn delete(
    vfs: *mut ffi::sqlite3_vfs,
    name: *const c_char,
    sync_directory: c_int,
) -> c_int {
    let Some(context) = (unsafe { context(vfs) }) else {
        return ffi::SQLITE_IOERR_DELETE;
    };
    let Some(child) = child_name(context, name) else {
        let Some(callback) = (unsafe { context.base.as_ref() }).and_then(|base| base.xDelete)
        else {
            return ffi::SQLITE_IOERR_DELETE;
        };
        return unsafe { callback(context.base, name, sync_directory) };
    };
    let Ok(child) = CString::new(child) else {
        return ffi::SQLITE_IOERR_DELETE;
    };
    if unsafe { libc::unlinkat(context.directory.as_raw_fd(), child.as_ptr(), 0) } != 0 {
        let error = io::Error::last_os_error();
        return if error.kind() == io::ErrorKind::NotFound {
            ffi::SQLITE_IOERR_DELETE_NOENT
        } else {
            ffi::SQLITE_IOERR_DELETE
        };
    }
    if sync_directory != 0 && context.directory.sync_all().is_err() {
        return ffi::SQLITE_IOERR_DIR_FSYNC;
    }
    ffi::SQLITE_OK
}

unsafe extern "C" fn access(
    vfs: *mut ffi::sqlite3_vfs,
    name: *const c_char,
    flags: c_int,
    result: *mut c_int,
) -> c_int {
    let Some(context) = (unsafe { context(vfs) }) else {
        return ffi::SQLITE_IOERR_ACCESS;
    };
    let Some(child) = child_name(context, name) else {
        let Some(callback) = (unsafe { context.base.as_ref() }).and_then(|base| base.xAccess)
        else {
            return ffi::SQLITE_IOERR_ACCESS;
        };
        return unsafe { callback(context.base, name, flags, result) };
    };
    if result.is_null() {
        return ffi::SQLITE_IOERR_ACCESS;
    }
    let Ok(child) = CString::new(child) else {
        return ffi::SQLITE_IOERR_ACCESS;
    };
    let mut stat = std::mem::MaybeUninit::uninit();
    let status = unsafe {
        libc::fstatat(
            context.directory.as_raw_fd(),
            child.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if status != 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::NotFound {
            unsafe { *result = 0 };
            return ffi::SQLITE_OK;
        }
        return ffi::SQLITE_IOERR_ACCESS;
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || stat.st_mode & 0o777 != 0o600
        || stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_nlink != 1
        || stat.st_dev as u64 != context.device
    {
        return ffi::SQLITE_IOERR_ACCESS;
    }
    let accessible = match flags {
        ffi::SQLITE_ACCESS_EXISTS | ffi::SQLITE_ACCESS_READ | ffi::SQLITE_ACCESS_READWRITE => true,
        _ => return ffi::SQLITE_IOERR_ACCESS,
    };
    unsafe { *result = c_int::from(accessible) };
    ffi::SQLITE_OK
}

unsafe extern "C" fn full_pathname(
    vfs: *mut ffi::sqlite3_vfs,
    name: *const c_char,
    output_length: c_int,
    output: *mut c_char,
) -> c_int {
    let Some(context) = (unsafe { context(vfs) }) else {
        return ffi::SQLITE_CANTOPEN;
    };
    let Some(child) = child_name(context, name) else {
        let Some(callback) = (unsafe { context.base.as_ref() }).and_then(|base| base.xFullPathname)
        else {
            return ffi::SQLITE_CANTOPEN;
        };
        return unsafe { callback(context.base, name, output_length, output) };
    };
    if output.is_null() || output_length <= 0 {
        return ffi::SQLITE_CANTOPEN;
    }
    let needed = context.prefix.len() + child.len() + 1;
    if needed > output_length as usize {
        return ffi::SQLITE_CANTOPEN;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(
            context.prefix.as_ptr(),
            output.cast::<u8>(),
            context.prefix.len(),
        );
        std::ptr::copy_nonoverlapping(
            child.as_ptr(),
            output.cast::<u8>().add(context.prefix.len()),
            child.len(),
        );
        *output.cast::<u8>().add(needed - 1) = 0;
    }
    ffi::SQLITE_OK
}

macro_rules! delegate {
    ($name:ident($($arg:ident: $ty:ty),*) -> $ret:ty, $field:ident, $fallback:expr) => {
        unsafe extern "C" fn $name(vfs: *mut ffi::sqlite3_vfs, $($arg: $ty),*) -> $ret {
            let Some(context) = (unsafe { context(vfs) }) else { return $fallback; };
            let Some(callback) = (unsafe { context.base.as_ref() }).and_then(|base| base.$field) else { return $fallback; };
            unsafe { callback(context.base, $($arg),*) }
        }
    };
}

delegate!(dl_open(name: *const c_char) -> *mut c_void, xDlOpen, std::ptr::null_mut());
delegate!(dl_error(length: c_int, message: *mut c_char) -> (), xDlError, ());
unsafe extern "C" fn dl_sym(
    vfs: *mut ffi::sqlite3_vfs,
    handle: *mut c_void,
    name: *const c_char,
) -> Option<unsafe extern "C" fn(*mut ffi::sqlite3_vfs, *mut c_void, *const c_char)> {
    let context = unsafe { context(vfs) }?;
    let callback = unsafe { context.base.as_ref() }?.xDlSym?;
    unsafe { callback(context.base, handle, name) }
}
delegate!(dl_close(handle: *mut c_void) -> (), xDlClose, ());
delegate!(randomness(length: c_int, output: *mut c_char) -> c_int, xRandomness, 0);
delegate!(sleep(microseconds: c_int) -> c_int, xSleep, 0);
delegate!(current_time(value: *mut f64) -> c_int, xCurrentTime, ffi::SQLITE_ERROR);
delegate!(last_error(length: c_int, message: *mut c_char) -> c_int, xGetLastError, 0);
delegate!(current_time_i64(value: *mut ffi::sqlite3_int64) -> c_int, xCurrentTimeInt64, ffi::SQLITE_ERROR);
delegate!(set_system_call(name: *const c_char, call: ffi::sqlite3_syscall_ptr) -> c_int, xSetSystemCall, ffi::SQLITE_NOTFOUND);
delegate!(get_system_call(name: *const c_char) -> ffi::sqlite3_syscall_ptr, xGetSystemCall, None);
delegate!(next_system_call(name: *const c_char) -> *const c_char, xNextSystemCall, std::ptr::null());
