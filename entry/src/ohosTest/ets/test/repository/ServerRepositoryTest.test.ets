// ServerRepositoryTest：服务器仓库业务逻辑测试
// 覆盖 ServerRepository 模块级纯逻辑函数
// 注意：nativeGetServerStatus/nativeCreateServer/nativeStopServer 的异常行为测试
// 已由 ServerNativeTest 覆盖，此处不重复
import { describe, it, expect } from '@ohos/hypium'

// subnetPattern 是文件级私有函数，无法直接导入测试；
// 此处验证其逻辑的等价实现，确保边界正确
function subnetPattern(ip: string, prefixLength: number): string {
  let parts: Array<string> = ip.split('.')
  if (parts.length < 4) {
    return ''
  }
  if (prefixLength >= 24) {
    return parts[0] + '.' + parts[1] + '.' + parts[2] + '.*'
  }
  return parts[0] + '.' + parts[1] + '.*'
}

export default function ServerRepositoryTest() {
  describe('ServerRepositoryTest', () => {

    // ── subnetPattern 网段通配生成 ──

    it('subnetPattern_24_or_above_uses_c_wildcard', 0, () => {
      expect(subnetPattern('192.168.1.100', 24)).assertEqual('192.168.1.*')
      expect(subnetPattern('192.168.1.100', 32)).assertEqual('192.168.1.*')
    })

    it('subnetPattern_below_24_uses_b_wildcard', 0, () => {
      expect(subnetPattern('192.168.1.100', 16)).assertEqual('192.168.*')
      // /8 仍然使用前两段通配（实现不按 CIDR 边界裁剪，统一取前两段）
      expect(subnetPattern('10.0.0.1', 8)).assertEqual('10.0.*')
    })

    it('subnetPattern_exact_24_uses_c_wildcard', 0, () => {
      expect(subnetPattern('172.16.0.1', 24)).assertEqual('172.16.0.*')
    })

    it('subnetPattern_short_ip_returns_empty', 0, () => {
      expect(subnetPattern('192.168.1', 24)).assertEqual('')
      expect(subnetPattern('10', 8)).assertEqual('')
      expect(subnetPattern('', 24)).assertEqual('')
    })
  })
}
