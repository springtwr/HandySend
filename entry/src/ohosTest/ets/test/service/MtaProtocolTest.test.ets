import { describe, it, expect } from '@ohos/hypium'
import {
  WsMessage,
  ReceiveRequest,
  P2pInfoJson,
  buildStatusPayload,
  buildWsMessage,
  extractJsonText,
  parseP2pInfo,
  parseSendRequestPayload,
  parseWsMessage
} from '../../../../main/ets/model/mta/MtaProtocolModels'

// MTA WS 消息 `type:id:name?json` 解析与构造、P2pInfo/sendRequest 解析的纯逻辑测试。
export default function MtaProtocolTest() {
  describe('MtaProtocolTest', () => {
    // ── parseWsMessage ──

    it('parse_version_negotiation', 0, () => {
      let message = parseWsMessage('action:0:versionNegotiation?{"version":1,"versions":[1]}')
      expect(message !== undefined).assertTrue()
      if (message !== undefined) {
        expect(message.type).assertEqual('action')
        expect(message.id).assertEqual(0)
        expect(message.name).assertEqual('versionNegotiation')
        expect(message.payload).assertEqual('{"version":1,"versions":[1]}')
      }
    })

    it('parse_send_request', 0, () => {
      let message = parseWsMessage('action:1:sendRequest?{"taskId":"t1"}')
      expect(message !== undefined).assertTrue()
      if (message !== undefined) {
        expect(message.type).assertEqual('action')
        expect(message.id).assertEqual(1)
        expect(message.name).assertEqual('sendRequest')
        expect(message.payload).assertEqual('{"taskId":"t1"}')
      }
    })

    it('parse_without_payload', 0, () => {
      let message = parseWsMessage('ack:1:sendRequest')
      expect(message !== undefined).assertTrue()
      if (message !== undefined) {
        expect(message.type).assertEqual('ack')
        expect(message.id).assertEqual(1)
        expect(message.name).assertEqual('sendRequest')
        expect(message.payload).assertEqual('')
      }
    })

    it('parse_invalid_returns_undefined', 0, () => {
      expect(parseWsMessage('garbage') === undefined).assertTrue()
      expect(parseWsMessage('action:abc:name') === undefined).assertTrue()
      expect(parseWsMessage('action:1:') === undefined).assertTrue()
      expect(parseWsMessage('') === undefined).assertTrue()
    })

    // ── buildWsMessage ──

    it('build_with_payload', 0, () => {
      let text = buildWsMessage('ack', 0, 'versionNegotiation', '{"version":1,"threadLimit":5}')
      expect(text).assertEqual('ack:0:versionNegotiation?{"version":1,"threadLimit":5}')
    })

    it('build_without_payload', 0, () => {
      let text = buildWsMessage('ack', 1, 'sendRequest', '')
      expect(text).assertEqual('ack:1:sendRequest')
    })

    // ── extractJsonText / parseP2pInfo ──

    it('extract_json_text_trims_noise', 0, () => {
      expect(extractJsonText('xx{"a":1}yy')).assertEqual('{"a":1}')
      expect(extractJsonText('no-brace')).assertEqual('no-brace')
    })

    it('parse_p2p_info_tolerates_wrapping_text', 0, () => {
      let info =
        parseP2pInfo('prefix{"id":"a1","ssid":"s","psk":"p","mac":"m","port":43210,"key":"k","catShare":7}suffix')
      expect(info !== undefined).assertTrue()
      if (info !== undefined) {
        expect(info.id).assertEqual('a1')
        expect(info.ssid).assertEqual('s')
        expect(info.psk).assertEqual('p')
        expect(info.mac).assertEqual('m')
        expect(info.port).assertEqual(43210)
        expect(info.key).assertEqual('k')
        expect(info.catShare).assertEqual(7)
      }
    })

    it('parse_p2p_info_invalid_returns_undefined', 0, () => {
      expect(parseP2pInfo('not json') === undefined).assertTrue()
    })

    // ── parseSendRequestPayload ──

    it('parse_send_request_payload', 0, () => {
      let request: ReceiveRequest | undefined = parseSendRequestPayload(
        '{"taskId":"t1","senderId":"s1","senderName":"m20","fileName":"a.zip","fileCount":2,"totalSize":1024}')
      expect(request !== undefined).assertTrue()
      if (request !== undefined) {
        expect(request.taskId).assertEqual('t1')
        expect(request.senderId).assertEqual('s1')
        expect(request.senderName).assertEqual('m20')
        expect(request.fileName).assertEqual('a.zip')
        expect(request.fileCount).assertEqual(2)
        expect(request.totalSize).assertEqual(1024)
      }
    })

    it('parse_send_request_payload_missing_fields_defaults', 0, () => {
      let request: ReceiveRequest | undefined = parseSendRequestPayload('{"taskId":"t2"}')
      expect(request !== undefined).assertTrue()
      if (request !== undefined) {
        expect(request.taskId).assertEqual('t2')
        expect(request.senderName).assertEqual('')
        expect(request.fileCount).assertEqual(0)
        expect(request.totalSize).assertEqual(0)
      }
    })

    it('parse_send_request_payload_falls_back_to_id', 0, () => {
      // 部分实现（如荣耀）只写 id，taskId 缺失时回退 id
      let request: ReceiveRequest | undefined = parseSendRequestPayload('{"id":"t9","senderName":"m20"}')
      expect(request !== undefined).assertTrue()
      if (request !== undefined) {
        expect(request.taskId).assertEqual('t9')
        expect(request.senderName).assertEqual('m20')
      }
    })

    it('parse_send_request_payload_prefers_task_id_over_id', 0, () => {
      let request: ReceiveRequest | undefined = parseSendRequestPayload('{"taskId":"t1","id":"t9"}')
      expect(request !== undefined).assertTrue()
      if (request !== undefined) {
        expect(request.taskId).assertEqual('t1')
      }
    })

    it('parse_send_request_payload_invalid_returns_undefined', 0, () => {
      expect(parseSendRequestPayload('not json') === undefined).assertTrue()
    })

    // ── buildStatusPayload ──

    it('build_status_payload_carries_task_id', 0, () => {
      let payload = buildStatusPayload('t1', 1, 'ok')
      expect(payload).assertEqual('{"taskId":"t1","type":1,"reason":"ok"}')
    })

    it('build_status_payload_escapes_special_chars', 0, () => {
      // taskId 来自对端，含引号等特殊字符时须转义为合法 JSON
      let payload = buildStatusPayload('a"b', 3, 'user refuse')
      let parsed = JSON.parse(payload) as Record<string, Object>
      expect(parsed['taskId'] as string).assertEqual('a"b')
    })

    // ── WsMessage 默认值 ──

    it('ws_message_defaults', 0, () => {
      let message = new WsMessage()
      expect(message.type).assertEqual('')
      expect(message.id).assertEqual(0)
      expect(message.name).assertEqual('')
      expect(message.payload).assertEqual('')
    })

    it('p2p_info_defaults', 0, () => {
      let info = new P2pInfoJson()
      expect(info.id).assertEqual('')
      expect(info.port).assertEqual(0)
      expect(info.key).assertEqual('')
      expect(info.catShare).assertEqual(0)
    })
  })
}
