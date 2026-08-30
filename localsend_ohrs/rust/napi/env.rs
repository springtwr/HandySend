//! NapiEnv——NAPI 层运行环境。
//!
//! 通过 `OnceLock` 全局持有 tokio Runtime + BridgeState 引用 + 事件流接收端
//! （决策 1/6）。桥接层函数不感知 runtime（FR-005）。
//!
//! - `block_on`：仅用于一次性操作（start_server 等）
//! - `start_event_forwarder`：spawn 消费事件流的异步 task，事件推送走
//!   napi_threadsafe_function（不阻塞 NAPI 调用线程）

use std::sync::{Arc, Mutex as StdMutex, OnceLock};

use tokio::sync::mpsc;

use crate::bridge::event::BridgeEvent;
use crate::bridge::state::bridge;

pub struct NapiEnv {
    /// 桥接层使用的 tokio Runtime（multi_thread, 2 workers）。
    pub runtime: tokio::runtime::Runtime,
    /// 全局 BridgeState 引用（与桥接层共享单例）。
    pub state: &'static Arc<StdMutex<crate::bridge::state::BridgeState>>,
    /// 事件流接收端（init 时设置，start_event_forwarder 消费）。
    pub event_rx: StdMutex<Option<mpsc::Receiver<BridgeEvent>>>,
}

impl NapiEnv {
    /// 返回全局 NapiEnv 单例。
    pub fn global() -> &'static NapiEnv {
        static ENV: OnceLock<NapiEnv> = OnceLock::new();
        ENV.get_or_init(|| NapiEnv {
            runtime: tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(2)
                .thread_name("handysend")
                .build()
                .expect("创建 tokio runtime 失败"),
            state: bridge(),
            event_rx: StdMutex::new(None),
        })
    }

    /// 在当前 runtime 上阻塞执行异步操作（仅用于一次性操作）。
    pub fn block_on<F: std::future::Future>(&self, f: F) -> F::Output {
        self.runtime.block_on(f)
    }

    /// 确保事件通道存在（幂等）。
    ///
    /// 事件流是桥接层的核心不变量——`state.event_tx` 必须存在，否则
    /// `send_event` 会静默丢弃所有 BridgeEvent。本函数在任何事件入口
    /// （init / create_server / start_server / start_discovery / send_files /
    /// register_event_listener）调用，保证不依赖调用顺序。
    ///
    /// 幂等性：`state.event_tx` 已存在（init 或先前入口已创建）时直接返回，
    /// 不重建通道（否则会丢失已启动的 forwarder 持有的旧 receiver）。
    pub fn ensure_event_channel(&self) {
        let mut s = self.state.lock().unwrap();
        if s.event_tx.is_some() {
            return;
        }
        let (event_tx, event_rx) = mpsc::channel::<BridgeEvent>(128);
        s.event_tx = Some(event_tx);
        let mut rx_slot = self.event_rx.lock().unwrap();
        *rx_slot = Some(event_rx);
    }
}
