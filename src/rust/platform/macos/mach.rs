//! UID共通の固定名とkernel管理のreceive right。pathnameの作成・回収は行わない。
use super::*;
use std::ffi::CString;
#[cfg(test)]
#[path = "mach_tests.rs"]
mod tests;

// 入力1MiBとは分離し、全items/診断を維持するWindows互換output budget。
const LIMIT: usize = 128 * 1024 * 1024;
const REQUEST: i32 = 0x50525131;
const RESPONSE: i32 = 0x50525231;
const COMPLEX: u32 = 0x8000_0000;
#[repr(C)]
#[derive(Default)]
struct Header {
    bits: u32,
    size: u32,
    remote: u32,
    local: u32,
    voucher: u32,
    id: i32,
}
unsafe extern "C" {
    static mach_task_self_: u32;
    static bootstrap_port: u32;
    fn mach_port_allocate(task: u32, right: i32, name: *mut u32) -> i32;
    fn mach_port_insert_right(task: u32, name: u32, poly: u32, kind: u32) -> i32;
    fn mach_port_destroy(task: u32, name: u32) -> i32;
    fn mach_port_deallocate(task: u32, name: u32) -> i32;
    fn mach_port_extract_right(
        task: u32,
        name: u32,
        kind: u32,
        poly: *mut u32,
        acquired: *mut u32,
    ) -> i32;
    fn mach_vm_allocate(task: u32, address: *mut u64, size: u64, flags: i32) -> i32;
    fn mach_msg(
        msg: *mut Header,
        options: u32,
        send: u32,
        receive: u32,
        port: u32,
        timeout: u32,
        notify: u32,
    ) -> i32;
    fn mach_msg_destroy(msg: *mut Header);
    fn bootstrap_register(bootstrap: u32, name: *const i8, port: u32) -> i32;
    fn bootstrap_look_up(bootstrap: u32, name: *const i8, port: *mut u32) -> i32;
    fn task_info(task: u32, flavor: i32, info: *mut u32, count: *mut u32) -> i32;
}
fn task() -> u32 {
    unsafe { mach_task_self_ }
}
#[derive(Clone, Copy, Debug)]
pub(super) struct Audit {
    pub uid: u32,
    pub pid: u32,
    pub version: u32,
}
pub(super) fn own_audit() -> Result<Audit> {
    let mut token = [0u32; 8];
    let mut count = 8;
    if unsafe { task_info(task(), 15, token.as_mut_ptr(), &mut count) } != 0 || count != 8 {
        bail!("Cannot obtain the kernel task audit identity");
    }
    Ok(Audit {
        uid: token[1],
        pid: token[5],
        version: token[7],
    })
}
pub(super) struct Receive(u32);
impl Receive {
    fn new() -> Result<Self> {
        let mut name = 0;
        if unsafe { mach_port_allocate(task(), 1, &mut name) } != 0 {
            bail!("Cannot allocate Mach receive right");
        }
        let port = Self(name);
        if unsafe { mach_port_insert_right(task(), name, name, 20) } != 0 {
            bail!("Cannot create Mach send right");
        }
        Ok(port)
    }
    pub fn register(name: &str) -> Result<Option<Self>> {
        let port = Self::new()?;
        let name = CString::new(name)?;
        let code = unsafe { bootstrap_register(bootstrap_port, name.as_ptr(), port.0) };
        match code {
            0 => Ok(Some(port)),
            1100 | 1101 => Ok(None),
            _ => bail!("Mach registration unavailable ({code})"),
        }
    }
    pub fn receive(&self, timeout: u32) -> Result<Option<Message>> {
        // 不明descriptorもkernel検証後のmessage全体をmach_msg_destroyへ返す。
        let mut message = Message {
            words: vec![0u32; 2048],
            received: false,
        };
        let code = unsafe {
            mach_msg(
                message.header(),
                2 | 0x100 | (3 << 24),
                0,
                (message.words.len() * 4) as u32,
                self.0,
                timeout,
                0,
            )
        };
        if code == 0x1000_4003 {
            return Ok(None);
        }
        // 上限超過messageはkernelが破棄済み。listener自体を終了しない。
        if code == 0x1000_4004 {
            return Ok(None);
        }
        // BODY_ERRORではcopyout済みの一部資源も通常の所有権で回収する。
        if code & !0x3e00 == 0x1000_400c {
            message.received = true;
            return Ok(None);
        }
        if code != 0 {
            bail!("Mach receive failed ({code:#x})");
        }
        message.received = true;
        Ok(Some(message))
    }
}
impl Drop for Receive {
    fn drop(&mut self) {
        unsafe {
            mach_port_destroy(task(), self.0);
        }
    }
}
struct Send(u32);
impl Drop for Send {
    fn drop(&mut self) {
        if self.0 != 0 {
            unsafe {
                mach_port_deallocate(task(), self.0);
            }
        }
    }
}
pub(super) struct Message {
    words: Vec<u32>,
    received: bool,
}
impl Message {
    fn header(&mut self) -> *mut Header {
        self.words.as_mut_ptr().cast()
    }
    fn bytes(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.words.as_ptr().cast(), self.words.len() * 4) }
    }
    pub fn audit(&self) -> Result<Audit> {
        let size = self.words[1] as usize;
        let offset = (size + 3) & !3;
        if size < 24 || offset + 52 > self.words.len() * 4 {
            bail!("Invalid Mach trailer offset");
        }
        let trailer = &self.words[offset / 4..];
        if trailer[0] != 0 || trailer[1] != 52 {
            bail!("Missing kernel audit trailer");
        }
        let audit = Audit {
            uid: trailer[6],
            pid: trailer[10],
            version: trailer[12],
        };
        if audit.uid != unsafe { libc::geteuid() } || audit.pid == 0 {
            bail!("Mach peer effective user mismatch");
        }
        Ok(audit)
    }
    pub fn request(&self) -> Result<Value> {
        self.audit()?;
        let size = self.words[1] as usize;
        if self.words[0] & COMPLEX != 0
            || self.words[0] & 0xff != 18
            || self.words[4] != 0
            || self.words[5] as i32 != REQUEST
            || !(32..=4096).contains(&size)
            || size > self.words.len() * 4
            || self.words[6] != 1
            || self.words[7] as usize > size - 32
        {
            bail!("Invalid inline Mach queue request");
        }
        Ok(serde_json::from_slice(
            &self.bytes()[32..32 + self.words[7] as usize],
        )?)
    }
    pub fn reply(&mut self, value: &Value) -> Result<()> {
        let payload = serde_json::to_vec(value)?;
        if payload.is_empty() || payload.len() > LIMIT {
            bail!("Mach result exceeds 128 MiB output budget");
        }
        if self.words[2] == 0 {
            bail!("Missing Mach reply right");
        }
        // 専用VMを送る。失敗時のpseudo-copyout資源もdestroyで回収でき、
        // Rust heapをMachのdeallocate対象へ混入させない。
        let mut address = 0u64;
        if unsafe { mach_vm_allocate(task(), &mut address, payload.len() as u64, 1) } != 0 {
            bail!("Cannot allocate bounded Mach result memory");
        }
        unsafe {
            std::ptr::copy_nonoverlapping(payload.as_ptr(), address as *mut u8, payload.len());
        }
        // mach_msg_ool_descriptor64_tはSDKのpack(4)、header24+body4+descriptor16。
        let mut words = vec![0u32; 11];
        words[0] = COMPLEX | 18;
        words[1] = 44;
        words[2] = self.words[2];
        self.words[2] = 0;
        words[5] = RESPONSE as u32;
        words[6] = 1;
        words[7] = address as u32;
        words[8] = (address >> 32) as u32;
        words[9] = 0x0100_0101;
        words[10] = payload.len() as u32;
        let mut outgoing = Message {
            words,
            received: true,
        };
        let code = unsafe { mach_msg(outgoing.header(), 1 | 0x10, 44, 0, 0, 2000, 0) };
        if code != 0 {
            bail!("Mach reply send failed ({code:#x})");
        }
        outgoing.received = false;
        Ok(())
    }
    fn response(&self) -> Result<Value> {
        self.audit()?;
        if self.words[0] & COMPLEX == 0
            || self.words[1] != 44
            || self.words[2] != 0
            || self.words[4] != 0
            || self.words[5] as i32 != RESPONSE
            || self.words[6] != 1
            || self.words[9] & 0xffff_0000 != 0x0100_0000
            || self.words[9] & 0xff > 1
            || (self.words[9] >> 8) & 0xff > 1
        {
            bail!("Invalid bounded Mach result descriptor");
        }
        let length = self.words[10] as usize;
        let address = u64::from(self.words[7]) | (u64::from(self.words[8]) << 32);
        if address == 0 || length == 0 || length > LIMIT {
            bail!("Invalid Mach result size");
        }
        // kernelがmappingを確立済み。所有権はMessageに残し成功・失敗ともdestroyする。
        let bytes = unsafe { std::slice::from_raw_parts(address as *const u8, length) };
        Ok(serde_json::from_slice(bytes)?)
    }
}
impl Drop for Message {
    fn drop(&mut self) {
        if self.received {
            // libsyscallのdestroyはVOLATILE_OOLを意図的にskipする。
            // overwrite無しの受信でkernelがこのtaskへ作成したmappingは、拒否時も
            // 通常OOLと同じ所有物として解放する（新たなdescriptor受入れではない）。
            if self.words[0] & COMPLEX != 0 {
                let size = self.words[1] as usize;
                let mut offset = 28usize;
                for _ in 0..self.words[6] {
                    if offset + 12 > size || offset + 12 > self.words.len() * 4 {
                        break;
                    }
                    let kind = self.words[(offset + 8) / 4] >> 24;
                    let length = if kind == 0 { 12 } else { 16 };
                    if offset + length > size || offset + length > self.words.len() * 4 {
                        break;
                    }
                    if matches!(kind, 1..=3) {
                        let flags = &mut self.words[(offset + 8) / 4];
                        *flags |= 1;
                        if kind == 3 {
                            *flags = (*flags & 0x00ff_ffff) | (1 << 24);
                        }
                    }
                    offset += length;
                }
            }
            unsafe {
                mach_msg_destroy(self.header());
            }
        }
    }
}
pub(super) fn contact(
    name: &str,
    request: &Value,
    expected: Option<Audit>,
) -> Result<Option<(Value, Audit)>> {
    let name = CString::new(name)?;
    let mut name_port = 0;
    let code = unsafe { bootstrap_look_up(bootstrap_port, name.as_ptr(), &mut name_port) };
    if code == 1102 {
        return Ok(None);
    }
    if code != 0 {
        bail!("Mach endpoint lookup unavailable ({code})");
    }
    let dest = Send(name_port);
    let receive = Receive::new()?;
    let payload = serde_json::to_vec(request)?;
    if payload.len() > 4000 {
        bail!("Mach control request too large");
    }
    if !send_request(dest, &receive, &payload, 2000)? {
        return Ok(None);
    }
    let message = receive
        .receive(3000)?
        .context("Mach queue worker did not respond")?;
    let audit = message.audit()?;
    if expected
        .is_some_and(|e| e.uid != audit.uid || e.pid != audit.pid || e.version != audit.version)
    {
        bail!("Mach worker audit identity changed");
    }
    Ok(Some((message.response()?, audit)))
}
fn send_request(mut dest: Send, receive: &Receive, payload: &[u8], timeout: u32) -> Result<bool> {
    let mut once = 0;
    let mut kind = 0;
    let code = unsafe { mach_port_extract_right(task(), receive.0, 21, &mut once, &mut kind) };
    if code != 0 {
        bail!("Cannot allocate explicit Mach reply right ({code})");
    }
    let mut once = Send(once);
    if kind != 18 {
        bail!("Unexpected Mach reply right disposition");
    }
    let size = (32 + payload.len() + 3) & !3;
    let mut words = vec![0u32; size / 4];
    // COPY/MAKEからの暗黙urefを残さず、明示所有した全権利をMOVEする。
    words[0] = 17 | (18 << 8);
    words[1] = size as u32;
    words[2] = dest.0;
    words[3] = once.0;
    words[5] = REQUEST as u32;
    words[6] = 1;
    words[7] = payload.len() as u32;
    unsafe {
        std::ptr::copy_nonoverlapping(
            payload.as_ptr(),
            words.as_mut_ptr().cast::<u8>().add(32),
            payload.len(),
        );
    }
    dest.0 = 0;
    once.0 = 0;
    let mut outgoing = Message {
        words,
        received: true,
    };
    let code = unsafe { mach_msg(outgoing.header(), 1 | 0x10, size as u32, 0, 0, timeout, 0) };
    if code == 0 {
        outgoing.received = false;
        return Ok(true);
    }
    // destroyはlocalを処理しない。pseudo-copyout後に返された名前で解放する。
    let local = Send(outgoing.words[3]);
    outgoing.words[3] = 0;
    drop(local);
    if code == 0x1000_0003 {
        return Ok(false);
    }
    if code != 0 {
        bail!("Mach request send failed ({code:#x})");
    }
    Ok(false)
}
