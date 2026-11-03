//! 自taskのkernel IPCだけで不正frameと受信資源の回収を確認する。
use super::*;

unsafe extern "C" {
    fn mach_port_get_refs(task: u32, name: u32, right: i32, refs: *mut u32) -> i32;
    fn mach_vm_region(
        task: u32,
        address: *mut u64,
        size: *mut u64,
        flavor: i32,
        info: *mut u32,
        count: *mut u32,
        object: *mut u32,
    ) -> i32;
    fn mach_port_names(
        task: u32,
        names: *mut *mut u32,
        name_count: *mut u32,
        types: *mut *mut u32,
        type_count: *mut u32,
    ) -> i32;
    fn mach_vm_deallocate(task: u32, address: u64, size: u64) -> i32;
    fn mach_port_mod_refs(task: u32, name: u32, right: i32, delta: i32) -> i32;
}
fn port_count() -> u32 {
    let mut names = std::ptr::null_mut();
    let mut types = std::ptr::null_mut();
    let mut nc = 0;
    let mut tc = 0;
    assert_eq!(
        unsafe { mach_port_names(task(), &mut names, &mut nc, &mut types, &mut tc) },
        0
    );
    unsafe {
        mach_vm_deallocate(task(), names as u64, u64::from(nc) * 4);
        mach_vm_deallocate(task(), types as u64, u64::from(tc) * 4);
    }
    nc
}
fn refs(port: &Receive) -> u32 {
    let mut count = 0;
    assert_eq!(
        unsafe { mach_port_get_refs(task(), port.0, 0, &mut count) },
        0
    );
    count
}
fn send(words: &mut [u32]) -> i32 {
    unsafe {
        mach_msg(
            words.as_mut_ptr().cast(),
            1 | 0x10,
            (words.len() * 4) as u32,
            0,
            0,
            1000,
            0,
        )
    }
}
fn header(words: &mut [u32], receiver: &Receive, id: i32) {
    words[0] = COMPLEX | 19;
    words[1] = (words.len() * 4) as u32;
    words[2] = receiver.0;
    words[5] = id as u32;
}
fn ool(words: &mut [u32], start: usize, address: usize, length: usize, kind: u32) {
    words[start] = address as u32;
    words[start + 1] = ((address as u64) >> 32) as u32;
    words[start + 2] = (kind << 24) | 0x100;
    words[start + 3] = length as u32;
}
fn mapped(address: usize) -> bool {
    let mut region = address as u64;
    let mut size = 0;
    let mut info = [0u32; 32];
    let mut count = 32;
    let mut object = 0;
    let code = unsafe {
        mach_vm_region(
            task(),
            &mut region,
            &mut size,
            9,
            info.as_mut_ptr(),
            &mut count,
            &mut object,
        )
    };
    if object != 0 {
        unsafe {
            mach_port_deallocate(task(), object);
        }
    }
    code == 0 && region <= address as u64 && (address as u64) < region + size
}
#[test]
fn malformed_complex_message_releases_copied_port_and_ool_memory() {
    let receiver = Receive::new().unwrap();
    let copied = Receive::new().unwrap();
    let baseline = refs(&copied);
    let data = vec![b'x'; 16384];
    for kind in [1, 3] {
        let mut words = vec![0u32; 14];
        header(&mut words, &receiver, RESPONSE);
        words[6] = 2;
        words[7] = copied.0;
        words[9] = 19 << 16;
        ool(&mut words, 10, data.as_ptr() as usize, data.len(), kind);
        assert_eq!(send(&mut words), 0);
        let message = receiver.receive(1000).unwrap().unwrap();
        assert!(message.audit().is_ok());
        assert!(message.request().is_err());
        assert!(message.response().is_err());
        assert_eq!(refs(&copied), baseline + 1);
        let address = u64::from(message.words[10]) | (u64::from(message.words[11]) << 32);
        assert!(mapped(address as usize));
        drop(message);
        assert_eq!(refs(&copied), baseline);
        assert!(!mapped(address as usize));
    }
}
#[test]
fn accepted_invalid_json_and_overbudget_ool_are_unmapped_on_every_return() {
    let receiver = Receive::new().unwrap();
    for length in [2usize, LIMIT + 1] {
        let memory = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                length,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1,
                0,
            )
        };
        assert_ne!(memory, libc::MAP_FAILED);
        let mut words = vec![0u32; 11];
        header(&mut words, &receiver, RESPONSE);
        words[6] = 1;
        ool(&mut words, 7, memory as usize, length, 1);
        assert_eq!(send(&mut words), 0);
        let message = receiver.receive(1000).unwrap().unwrap();
        let address = u64::from(message.words[7]) | (u64::from(message.words[8]) << 32);
        assert!(mapped(address as usize));
        assert!(message.response().is_err());
        drop(message);
        assert!(!mapped(address as usize));
        assert_eq!(unsafe { libc::munmap(memory, length) }, 0);
    }
}
#[test]
fn too_large_inline_receive_reclaims_kernel_copied_rights() {
    let receiver = Receive::new().unwrap();
    let copied = Receive::new().unwrap();
    let baseline = refs(&copied);
    let mut words = vec![0u32; 4096];
    header(&mut words, &receiver, REQUEST);
    words[6] = 1;
    words[7] = copied.0;
    words[9] = 19 << 16;
    assert_eq!(send(&mut words), 0);
    assert_eq!(refs(&copied), baseline);
    assert!(receiver.receive(1000).unwrap().is_none());
    assert_eq!(refs(&copied), baseline);
}

#[test]
fn rejected_ool_port_array_releases_each_right_and_mapping() {
    let receiver = Receive::new().unwrap();
    let copied = Receive::new().unwrap();
    let baseline = refs(&copied);
    let names = [copied.0];
    let mut words = vec![0u32; 11];
    header(&mut words, &receiver, RESPONSE);
    words[6] = 1;
    ool(&mut words, 7, names.as_ptr() as usize, 1, 2);
    words[9] |= 19 << 16;
    assert_eq!(send(&mut words), 0);
    let message = receiver.receive(1000).unwrap().unwrap();
    assert!(message.response().is_err());
    let address = u64::from(message.words[7]) | (u64::from(message.words[8]) << 32);
    assert_eq!(refs(&copied), baseline + 1);
    assert!(mapped(address as usize));
    drop(message);
    assert_eq!(refs(&copied), baseline);
    assert!(!mapped(address as usize));
}

#[test]
fn request_timeout_and_dead_peer_reclaim_pseudo_receive_header_rights() {
    let dest = Receive::new().unwrap();
    let reply = Receive::new().unwrap();
    // 新規Mach portの既定queue limitは5。満杯にして送信のpseudo-receiveを通す。
    for _ in 0..5 {
        let mut words = vec![0u32; 6];
        words[0] = 19;
        words[1] = 24;
        words[2] = dest.0;
        assert_eq!(send(&mut words), 0);
    }
    let baseline = port_count();
    let baseline_refs = refs(&dest);
    for _ in 0..16 {
        assert_eq!(
            unsafe { mach_port_insert_right(task(), dest.0, dest.0, 20) },
            0
        );
        let error = send_request(Send(dest.0), &reply, b"{}", 0).unwrap_err();
        assert!(error.to_string().contains("0x10000004"), "{error}");
        assert_eq!(refs(&dest), baseline_refs);
        assert_eq!(port_count(), baseline);
    }
    for _ in 0..16 {
        let dead = Receive::new().unwrap();
        let name = dead.0;
        assert_eq!(unsafe { mach_port_mod_refs(task(), name, 1, -1) }, 0);
        std::mem::forget(dead);
        assert!(!send_request(Send(name), &reply, b"{}", 0).unwrap());
        assert_eq!(port_count(), baseline);
    }
}

#[test]
fn reply_to_disappeared_receiver_consumes_send_once_resources() {
    let endpoint = Receive::new().unwrap();
    let baseline = port_count();
    let reply = Receive::new().unwrap();
    assert_eq!(
        unsafe { mach_port_insert_right(task(), endpoint.0, endpoint.0, 20) },
        0
    );
    assert!(send_request(Send(endpoint.0), &reply, b"{}", 0).unwrap());
    let mut request = endpoint.receive(1000).unwrap().unwrap();
    drop(reply);
    // dead send-once宛てはkernelがmessageを消費して成功を返す。
    assert!(
        request
            .reply(&json!({"result":"owned VM failure fixture"}))
            .is_ok()
    );
    drop(request);
    assert_eq!(port_count(), baseline);
}
