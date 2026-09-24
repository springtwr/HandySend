// ActiveSessionFilterTest：listActiveSessionsByProtocolKeys 过滤口径测试
// 覆盖：命中协议键的活跃会话纳入、待确认（awaitingConfirmation）纳入、
// 终态会话排除、协议键不匹配的会话排除。
// 断言口径：按会话标识在查询结果中包含性断言（注册表为全局单例，不假设结果总数）。
import { describe, it, expect } from '@ohos/hypium'
import {
  createSession,
  finish,
  listActiveSessionsByProtocolKeys
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionCapabilities,
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  SessionStage,
  TransferSession
} from '../../../../main/ets/model/transfer/TransferSession'
import { LOCAL_SEND_KEY } from '../../../../main/ets/service/transfer/adapters/LocalSendSendAdapter'
import { LOCAL_RECEIVE_KEY } from '../../../../main/ets/service/transfer/adapters/LocalSendReceiveAdapter'
import { MTA_SEND_KEY } from '../../../../main/ets/service/transfer/adapters/MtaSendAdapter'
import { WEB_DOWNLOAD_KEY } from '../../../../main/ets/service/transfer/adapters/WebDownloadAdapter'

// 测试内构造的最小能力声明（可取消，其余能力与过滤口径无关）
function testCapabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: false,
    hasByteProgress: false,
    canSaveToGallery: false,
    hasVerify: false
  }
}

let seq: number = 0

// 创建一个测试会话（指定协议键与阶段，方向固定为本机发送）
function beginSession(protocolKey: string, stage: SessionStage): string {
  seq++
  let input: SessionCreateInput = {
    protocolKey: protocolKey,
    protocolSessionId: 'filter-test-' + seq,
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: { displayName: 'FilterTest 对端', badges: [] },
    files: [{
      fileId: 'filter-test-file-' + seq,
      fileName: 'filter-test.bin',
      fileType: '',
      totalBytes: 1
    }],
    capabilities: testCapabilities(),
    stage: stage
  }
  let session = createSession(input)
  return session.id
}

// 判断会话标识是否出现在查询结果中
function containsSession(result: Array<TransferSession>, sessionId: string): boolean {
  for (let i = 0; i < result.length; i++) {
    if (result[i].id === sessionId) {
      return true
    }
  }
  return false
}

export default function ActiveSessionFilterTest() {
  describe('ActiveSessionFilterTest', () => {

    // 命中协议键：进行中与待确认会话均纳入（LocalSend 范围键集）
    it('includes_active_and_awaiting_sessions_of_matched_keys', 0, () => {
      let activeId: string = beginSession(LOCAL_SEND_KEY, SessionStage.active)
      let awaitingId: string = beginSession(WEB_DOWNLOAD_KEY, SessionStage.awaitingConfirmation)
      let keys: Array<string> = [LOCAL_SEND_KEY, LOCAL_RECEIVE_KEY, WEB_DOWNLOAD_KEY]
      let result: Array<TransferSession> = listActiveSessionsByProtocolKeys(keys)
      expect(containsSession(result, activeId)).assertTrue()
      expect(containsSession(result, awaitingId)).assertTrue()
    })

    // 终态排除：会话终结后不再出现在查询结果中
    it('excludes_terminal_sessions', 0, () => {
      let id: string = beginSession(LOCAL_RECEIVE_KEY, SessionStage.active)
      let keys: Array<string> = [LOCAL_SEND_KEY, LOCAL_RECEIVE_KEY, WEB_DOWNLOAD_KEY]
      expect(containsSession(listActiveSessionsByProtocolKeys(keys), id)).assertTrue()
      finish(id, SessionStage.succeeded)
      expect(containsSession(listActiveSessionsByProtocolKeys(keys), id)).assertFalse()
    })

    // 协议键不匹配排除：MTA 会话不出现在 LocalSend 键集结果中，出现在 MTA 键集结果中
    it('excludes_unmatched_protocol_keys', 0, () => {
      let id: string = beginSession(MTA_SEND_KEY, SessionStage.active)
      let localSendKeys: Array<string> = [LOCAL_SEND_KEY, LOCAL_RECEIVE_KEY, WEB_DOWNLOAD_KEY]
      expect(containsSession(listActiveSessionsByProtocolKeys(localSendKeys), id)).assertFalse()
      let mtaKeys: Array<string> = [MTA_SEND_KEY]
      expect(containsSession(listActiveSessionsByProtocolKeys(mtaKeys), id)).assertTrue()
    })
  })
}
