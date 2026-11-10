// SendRepositoryTest：发送仓库业务逻辑测试
// 覆盖 sendResultErrorMessage 错误消息映射（纯逻辑，不需要服务器运行）
// 注意：nativeGetCurrentSendSessionId/nativeCancelTransferLocal/nativeCancelLocalSession
// 的异常行为测试已由 SendNativeTest 覆盖，此处不重复
//
// ── 以下业务逻辑因需多设备配合，单设备无法测试 ──
// 1. 完整发送流程：prepareUpload → fileUpload → uploadProgress → sessionEnd
// 2. 多文件并行上传时 fileId 的正确路由与进度追踪
// 3. 取消发送后接收方收到 cancelReceived 事件的联动验证
// 4. 传输中断（网络断开）后的超时检测与错误状态恢复
import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'

// sendResultErrorMessage 依赖 getAppContext()，在无 UIAbilityContext 时回退到硬编码英文消息
// 因此可以在 instrument test 环境下验证回退逻辑
import {
  clearAllSendSessions,
  createSendSession,
  prepareSendFiles,
  sendResultErrorMessage,
  sendToDevice,
  updateSendSessionStatus
} from '../../../../main/ets/service/repository/SendRepository'
import { cancel, resetRegistry } from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import { NativeHttpError } from '../../../../main/ets/model/NativeTypes'
import { DiscoveredDevice, SendFileItem, SendSessionStatus } from '../../../../main/ets/model/Types'
import { writeTestFileToSandbox } from '../helper/TestHelper'

function makeError(kind: string, status?: number, message?: string): NativeHttpError {
  let err: NativeHttpError = {
    kind: kind,
    status: status,
    message: message
  }
  return err
}

export default function SendRepositoryTest() {
  describe('SendRepositoryTest', () => {

    // ── sendResultErrorMessage：HTTP 状态码映射 ──
    // instrument test 环境不启动主 EntryAbility，getAppContext() 为 undefined，
    // localizedText 走硬编码英文回退，故可精确断言回退文案

    it('sendResultErrorMessage_401_returns_pin_message', 0, () => {
      let err: NativeHttpError = makeError('statusCode', 401)
      let msg: string = sendResultErrorMessage(err)
      expect(msg).assertEqual('PIN required')
    })

    it('sendResultErrorMessage_403_returns_declined_message', 0, () => {
      let err: NativeHttpError = makeError('statusCode', 403)
      let msg: string = sendResultErrorMessage(err)
      expect(msg).assertEqual('Receiver declined')
    })

    it('sendResultErrorMessage_429_returns_too_many_message', 0, () => {
      let err: NativeHttpError = makeError('statusCode', 429)
      let msg: string = sendResultErrorMessage(err)
      expect(msg).assertEqual('Too many attempts, try later')
    })

    it('sendResultErrorMessage_409_returns_busy_message', 0, () => {
      let err: NativeHttpError = makeError('statusCode', 409)
      let msg: string = sendResultErrorMessage(err)
      expect(msg).assertEqual('Recipient is busy, please try again later')
    })

    it('sendResultErrorMessage_unknown_status_falls_through', 0, () => {
      let err: NativeHttpError = makeError('statusCode', 500, 'Internal Server Error')
      let msg: string = sendResultErrorMessage(err)
      // 未知状态码 + 有 message → 返回 message
      expect(msg === 'Internal Server Error').assertTrue()
    })

    it('sendResultErrorMessage_unknown_status_no_message_returns_http_code', 0, () => {
      let err: NativeHttpError = makeError('statusCode', 503)
      // 无 message → 返回 'HTTP 503'
      expect(sendResultErrorMessage(err)).assertEqual('HTTP 503')
    })

    // ── sendResultErrorMessage：reqwest 错误映射 ──

    it('sendResultErrorMessage_reqwest_timeout_mapped', 0, () => {
      let err: NativeHttpError = makeError('reqwest', undefined, 'operation timed out')
      let msg: string = sendResultErrorMessage(err)
      expect(msg).assertEqual('Receiver did not respond')
    })

    it('sendResultErrorMessage_reqwest_connection_refused_mapped', 0, () => {
      let err: NativeHttpError = makeError('reqwest', undefined, 'connection refused')
      let msg: string = sendResultErrorMessage(err)
      expect(msg).assertEqual('Receiver did not respond')
    })

    it('sendResultErrorMessage_reqwest_other_keeps_original_message', 0, () => {
      let err: NativeHttpError = makeError('reqwest', undefined, 'some protocol error')
      let msg: string = sendResultErrorMessage(err)
      expect(msg === 'some protocol error').assertTrue()
    })

    it('sendResultErrorMessage_cancelled_mapped', 0, () => {
      let err: NativeHttpError = makeError('cancelled', undefined, 'cancelled by user')
      let msg: string = sendResultErrorMessage(err)
      expect(msg).assertEqual('Transfer cancelled by receiver')
    })

    // ── sendResultErrorMessage：边界 ──

    it('sendResultErrorMessage_undefined_returns_empty', 0, () => {
      let msg: string = sendResultErrorMessage(undefined)
      expect(msg === '').assertTrue()
    })

    it('sendResultErrorMessage_other_kind_with_message', 0, () => {
      let err: NativeHttpError = makeError('other', undefined, 'custom error')
      let msg: string = sendResultErrorMessage(err)
      expect(msg === 'custom error').assertTrue()
    })

    it('sendResultErrorMessage_other_kind_no_message', 0, () => {
      let err: NativeHttpError = makeError('other')
      let msg: string = sendResultErrorMessage(err)
      // 无可读消息的未知错误统一回退为连接失败文案
      expect(msg).assertEqual('Connection failed')
    })

    // ── prepareSendFiles：源文件修改时间透传 ──
    // 网页 zip 条目按该字段还原文件时间；缺失时会回退为当前时间。

    it('prepareSendFiles_carries_source_mtime', 0, async (done: Function) => {
      let path: string = writeTestFileToSandbox('prepare_mtime_' + Date.now() + '.txt', 'mtime')
      let expected: number = Math.floor(fs.statSync(path).mtime * 1000)
      let items: Array<SendFileItem> = await prepareSendFiles([path])
      expect(items.length).assertEqual(1)
      expect(items[0].lastModified).assertEqual(expected)
      done()
    })

    // ── 发送启动前的终态守卫 ──
    // 会话已取消时，即使尚未打开文件也不得再启动后端发送。

    it('sendToDevice_abortsWhenUnifiedSessionCancelled', 0, async (done: Function) => {
      resetRegistry()
      clearAllSendSessions()
      let device: DiscoveredDevice = {
        alias: 'AbortPeer',
        ip: '192.168.1.99',
        port: 53317,
        fingerprint: 'abort-fp',
        version: '2.2',
        deviceModel: 'Model',
        deviceType: 'mobile',
        protocol: 'http',
        lastSeen: 0,
        channels: []
      }
      let files: Array<SendFileItem> = [{
        fileId: 'abort_f1',
        filePath: '/nonexistent/abort.txt',
        fileName: 'abort.txt',
        fileType: 'text/plain',
        size: 1
      }]
      let unifiedId: string = createSendSession('abort_case', device.ip, device.alias, files, device)
      cancel(unifiedId)
      let result = await sendToDevice(device, files, 'send_abort_case', unifiedId)
      expect(result.success).assertFalse()
      if (result.error !== undefined) {
        expect(result.error.kind).assertEqual('cancelled')
      }
      updateSendSessionStatus('abort_case', SendSessionStatus.cancelled)
      clearAllSendSessions()
      resetRegistry()
      done()
    })
  })
}
