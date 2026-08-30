// SecurityNativeTest：安全上下文 NativeBridge 函数测试
// 覆盖 nativeGetSecurityContext/nativeResetSecurityContext
// getSecurityContext 不需要服务器运行；resetSecurityContext 需要 BridgeState.save_dir 可写
import { describe, it, expect } from '@ohos/hypium'
import {
  nativeGetSecurityContext,
  nativeResetSecurityContext
} from '../../../../main/ets/service/NativeBridge'
import { NativeSecurityContext } from '../../../../main/ets/model/NativeTypes'

export default function SecurityNativeTest() {
  describe('SecurityNativeTest', () => {

    // ── nativeGetSecurityContext ──
    // 不需要服务器运行

    it('getSecurityContext_all_fields_nonempty', 0, () => {
      let ctx: NativeSecurityContext = nativeGetSecurityContext()
      // 一次验证所有字段非空——同一 SecurityContext 对象各字段要么全有要么全无
      expect(ctx.certificateHash !== undefined && ctx.certificateHash.length > 0).assertTrue()
      expect(ctx.certificate !== undefined && ctx.certificate.length > 0).assertTrue()
      expect(ctx.publicKey !== undefined && ctx.publicKey.length > 0).assertTrue()
    })

    // ── nativeResetSecurityContext ──
    // resetSecurityContext 需要写盘保存 TLS 身份到 save_dir
    // 若服务器未启动（默认 save_dir=/data/local/tmp/localsend/），写盘可能失败
    // 若服务器已启动（save_dir 为测试可写目录），写盘应成功
    // 两种场景都验证

    it('resetSecurityContext_changes_hash_or_preserves_on_failure', 0, () => {
      // resetSecurityContext 需要写盘保存 TLS 身份到 save_dir
      // 无论服务器是否运行，都可能因 save_dir 不可写而失败
      let ctxBefore: NativeSecurityContext = nativeGetSecurityContext()
      let hashBefore: string = ctxBefore.certificateHash

      try {
        let newCtx: NativeSecurityContext = nativeResetSecurityContext()
        // 写盘成功：
        // 1) 返回新的安全上下文，哈希应不同（每次生成新的 RSA 密钥对）
        expect(newCtx.certificateHash !== undefined).assertTrue()
        expect(newCtx.certificateHash.length > 0).assertTrue()
        expect(hashBefore !== newCtx.certificateHash).assertTrue()
      } catch (_e) {
        // 写盘失败（Permission denied 等）：
        // 验证内存态未被破坏——哈希应与重置前相同
        let ctxAfter: NativeSecurityContext = nativeGetSecurityContext()
        expect(hashBefore === ctxAfter.certificateHash).assertTrue()
      }
    })
  })
}
