import { describe, it, expect } from '@ohos/hypium'
import {
  ConnectRoute,
  P2P_DEVICE_ADDR_TYPE_RANDOM,
  P2P_DEVICE_ADDR_TYPE_REAL,
  P2P_NET_ID_PERSISTENT,
  P2P_NET_ID_TEMP,
  P2pPeerDeviceView,
  WsAttemptRecord,
  WsFailureKind,
  WsHandshakeResult,
  buildWsHandshakeSummary,
  connectRouteText,
  deriveDeviceAddressType,
  formatWsAttemptLine,
  p2pNetIdText,
  pickP2pPeerIndex,
  wsFailureKindText
} from '../main/ets/model/mta/MtaReceiveModels'

// 连接路线文本与 WS 握手诊断纯函数测试（路线文案、失败类型文案、尝试时间线、结果摘要）。
export default function MtaReceiveModelsTest() {
  describe('MtaReceiveModelsTest', () => {
    // ── 连接路线文本 ──

    it('connect_route_text', 0, () => {
      expect(connectRouteText(ConnectRoute.CREDENTIAL)).assertEqual('凭据直连')
      expect(connectRouteText(ConnectRoute.P2P_CONNECT)).assertEqual('p2pConnect')
    })

    // ── WS 失败类型文本 ──

    it('ws_failure_kind_text', 0, () => {
      expect(wsFailureKindText(WsFailureKind.NONE)).assertEqual('无')
      expect(wsFailureKindText(WsFailureKind.TIMEOUT)).assertEqual('超时')
      expect(wsFailureKindText(WsFailureKind.ERROR)).assertEqual('error 事件')
      expect(wsFailureKindText(WsFailureKind.CONNECT_REJECT)).assertEqual('发起拒绝')
    })

    // ── WS 尝试时间线 ──

    it('format_ws_attempt_success', 0, () => {
      let record = new WsAttemptRecord()
      record.round = 2
      record.success = true
      record.costMs = 120
      expect(formatWsAttemptLine(record)).assertEqual('第 2 轮：成功 耗时 120ms')
    })

    it('format_ws_attempt_timeout_without_code', 0, () => {
      let record = new WsAttemptRecord()
      record.round = 1
      record.success = false
      record.costMs = 3001
      record.failureKind = WsFailureKind.TIMEOUT
      record.failureCode = ''
      record.failureText = 'WS 连接超时（3000ms）'
      expect(formatWsAttemptLine(record)).assertEqual('第 1 轮：失败（超时） 耗时 3001ms WS 连接超时（3000ms）')
    })

    it('format_ws_attempt_error_event_with_code', 0, () => {
      let record = new WsAttemptRecord()
      record.round = 3
      record.success = false
      record.costMs = 45
      record.failureKind = WsFailureKind.ERROR
      record.failureCode = '2301002'
      record.failureText = '连接错误'
      expect(formatWsAttemptLine(record)).assertEqual('第 3 轮：失败（error 事件） 耗时 45ms code=2301002 连接错误')
    })

    // ── WS 握手结果摘要 ──

    it('build_ws_handshake_summary_counts_attempts', 0, () => {
      let result = new WsHandshakeResult()
      result.targetUrl = 'wss://192.168.49.1:43210/websocket'
      result.success = false
      result.totalMs = 12000
      let first = new WsAttemptRecord()
      first.round = 1
      result.attempts.push(first)
      let second = new WsAttemptRecord()
      second.round = 2
      result.attempts.push(second)
      expect(buildWsHandshakeSummary(result))
        .assertEqual('目标 wss://192.168.49.1:43210/websocket：失败，共 2 轮，总耗时 12000ms')
    })

    // ── 默认值 ──

    it('ws_handshake_result_defaults', 0, () => {
      let result = new WsHandshakeResult()
      expect(result.targetUrl).assertEqual('')
      expect(result.success).assertFalse()
      expect(result.totalMs).assertEqual(0)
      expect(result.summary).assertEqual('')
      expect(result.attempts.length).assertEqual(0)
    })

    // ── p2pConnect 地址类型推导与 netId 文案 ──

    it('derive_device_address_type_random', 0, () => {
      // 22:d0:98:12:82:08 首字节 0x22，本地管理位为 1 → 随机地址
      expect(deriveDeviceAddressType('22:d0:98:12:82:08')).assertEqual(P2P_DEVICE_ADDR_TYPE_RANDOM)
    })

    it('derive_device_address_type_real', 0, () => {
      // b8:7a:eb:7a:69:1d 首字节 0xb8，本地管理位为 0 → 真实地址
      expect(deriveDeviceAddressType('b8:7a:eb:7a:69:1d')).assertEqual(P2P_DEVICE_ADDR_TYPE_REAL)
    })

    it('derive_device_address_type_invalid_defaults_random', 0, () => {
      expect(deriveDeviceAddressType('')).assertEqual(P2P_DEVICE_ADDR_TYPE_RANDOM)
    })

    it('p2p_net_id_text', 0, () => {
      expect(p2pNetIdText(P2P_NET_ID_TEMP)).assertEqual('临时组 (-1)')
      expect(p2pNetIdText(P2P_NET_ID_PERSISTENT)).assertEqual('永久组 (-2)')
    })

    // ── P2P 发现对端匹配 ──

    it('pick_p2p_peer_by_exact_address', 0, () => {
      let peers: Array<P2pPeerDeviceView> = []
      let first = new P2pPeerDeviceView()
      first.deviceAddress = 'aa:bb:cc:dd:ee:01'
      peers.push(first)
      let second = new P2pPeerDeviceView()
      second.deviceAddress = '22:D0:98:12:82:08'
      peers.push(second)
      expect(pickP2pPeerIndex(peers, '22:d0:98:12:82:08')).assertEqual(1)
    })

    it('pick_p2p_peer_single_non_matching_falls_back', 0, () => {
      let peers: Array<P2pPeerDeviceView> = []
      let only = new P2pPeerDeviceView()
      only.deviceAddress = 'aa:bb:cc:dd:ee:01'
      peers.push(only)
      expect(pickP2pPeerIndex(peers, '22:d0:98:12:82:08')).assertEqual(0)
    })

    it('pick_p2p_peer_ambiguous_returns_minus_one', 0, () => {
      let peers: Array<P2pPeerDeviceView> = []
      let first = new P2pPeerDeviceView()
      first.deviceAddress = 'aa:bb:cc:dd:ee:01'
      peers.push(first)
      let second = new P2pPeerDeviceView()
      second.deviceAddress = 'aa:bb:cc:dd:ee:02'
      peers.push(second)
      expect(pickP2pPeerIndex(peers, '22:d0:98:12:82:08')).assertEqual(-1)
    })

    it('pick_p2p_peer_empty_returns_minus_one', 0, () => {
      let peers: Array<P2pPeerDeviceView> = []
      expect(pickP2pPeerIndex(peers, '22:d0:98:12:82:08')).assertEqual(-1)
    })
  })
}
