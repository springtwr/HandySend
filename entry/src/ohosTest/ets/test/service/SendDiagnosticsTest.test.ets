// 发送侧交互诊断纯函数用例：取消目标选择 / 会话结束事件归属判定 / 原生错误事件 → 诊断文本。
// 这些判定涉及 IPC 或真实发送链路，无法直接触发，故把「决策」抽为可导出纯函数以便确定性断言。
import { describe, it, expect } from '@ohos/hypium'
import { decideCancelTarget } from '../../../../main/ets/service/transfer/adapters/LocalSendSendAdapter'
import { isLocalReceiveSessionId } from '../../../../main/ets/service/repository/ReceiveRepository'
import { formatNativeErrorDiagnostic } from '../../../../main/ets/service/AppService'
import { NativeErrorEvent } from '../../../../main/ets/model/NativeTypes'

export default function SendDiagnosticsTest() {
  describe('SendDiagnosticsTest', () => {
    it('cancelTarget_onlyProtocolId_elseNoDispatch', 0, () => {
      // 协议标识可用：返回可下发目标（握手后的接收方标识 / 握手期标识）
      expect(decideCancelTarget('recv-uuid-1')).assertEqual('recv-uuid-1')
      expect(decideCancelTarget('prepare_10.0.0.1')).assertEqual('prepare_10.0.0.1')
      // 取不到协议标识：返回空串表示不下发，不回退到任何应用内部业务编号
      expect(decideCancelTarget('')).assertEqual('')
    })

    it('sessionEndAttribution_onlyLocalReceiveSession', 0, () => {
      let known: Array<string> = ['recv-uuid-1', 'recv-uuid-2']
      // 确属本机接收会话：可处理
      expect(isLocalReceiveSessionId('recv-uuid-1', known)).assertTrue()
      expect(isLocalReceiveSessionId('recv-uuid-2', known)).assertTrue()
      // 发送方向标识（不在接收侧状态表）：判定为忽略
      expect(isLocalReceiveSessionId('send-multi_1', known)).assertFalse()
      // 陌生标识与空标识：忽略
      expect(isLocalReceiveSessionId('unknown', known)).assertFalse()
      expect(isLocalReceiveSessionId('', known)).assertFalse()
    })

    it('nativeErrorDiagnostic_structuredAndAttribution', 0, () => {
      let event: NativeErrorEvent = { type: 'error', context: 'send', message: 'connection reset' }
      // 结构化字段齐全，可归属时含会话标识
      let attributable = formatNativeErrorDiagnostic(event, 'sess-1')
      expect(attributable.indexOf('上下文=send') >= 0).assertTrue()
      expect(attributable.indexOf('消息=connection reset') >= 0).assertTrue()
      expect(attributable.indexOf('会话=sess-1') >= 0).assertTrue()
      // 不可归属时明确标注，不伪造标识
      let orphan = formatNativeErrorDiagnostic(event, '')
      expect(orphan.indexOf('会话=不可归属') >= 0).assertTrue()
    })
  })
}
