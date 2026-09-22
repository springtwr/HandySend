// ServerRepositoryTest：服务器仓库业务逻辑测试
// 覆盖 ServerRepository/SettingsRepository 的网络接口相关纯逻辑：
// - subnetPattern：网段通配生成（真实实现）
// - computeDiscoveryWhitelistFrom：白名单匹配 / 黑名单优先排除 / 去重
// - ensureDefaultNetworkLists：首次启动按接口类型初始化白/黑名单
// 注意：nativeGetServerStatus/nativeCreateServer/nativeStopServer 的异常行为测试
// 已由 ServerNativeTest 覆盖，此处不重复
import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  subnetPattern,
  computeDiscoveryWhitelistFrom
} from '../../../../main/ets/service/repository/ServerRepository'
import {
  ensureDefaultNetworkLists,
  getNetworkWhitelist,
  setNetworkWhitelist,
  getNetworkBlacklist,
  setNetworkBlacklist
} from '../../../../main/ets/service/repository/SettingsRepository'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'
import { NetworkInterface, NetworkType } from '../../../../main/ets/model/Types'

function makeIface(name: string, ip: string, prefixLength: number, type: NetworkType): NetworkInterface {
  return {
    name: name,
    ip: ip,
    prefixLength: prefixLength,
    type: type,
    isDefault: false
  }
}

export default function ServerRepositoryTest() {
  describe('ServerRepositoryTest', () => {

    beforeAll(() => {
      // 初始化偏好存储（测试环境未走 App 主流程，preferences 未初始化；
      // 白/黑名单读写依赖它）
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    // ── subnetPattern 网段通配生成（真实实现）──

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

    // ── computeDiscoveryWhitelistFrom 白名单计算 ──

    it('whitelist_matches_interfaces_to_wildcards', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi),
        makeIface('eth0', '10.0.0.1', 16, NetworkType.ethernet),
        makeIface('rmnet0', '100.64.0.1', 32, NetworkType.cellular)
      ]
      let result = computeDiscoveryWhitelistFrom(['wlan0', 'eth0'], [], interfaces)
      expect(result !== undefined).assertTrue()
      if (result !== undefined) {
        expect(result.length === 2).assertTrue()
        expect(result.indexOf('192.168.1.*') >= 0).assertTrue()
        expect(result.indexOf('10.0.*') >= 0).assertTrue()
      }
    })

    it('whitelist_blacklist_exclusion_takes_priority', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi),
        makeIface('eth0', '10.0.0.1', 16, NetworkType.ethernet)
      ]
      // wlan0 同时出现在白名单与黑名单——黑名单优先排除
      let result = computeDiscoveryWhitelistFrom(['wlan0', 'eth0'], ['wlan0'], interfaces)
      expect(result !== undefined).assertTrue()
      if (result !== undefined) {
        expect(result.length === 1).assertTrue()
        expect(result.indexOf('10.0.*') >= 0).assertTrue()
        expect(result.indexOf('192.168.1.*') < 0).assertTrue()
      }
    })

    it('whitelist_deduplicates_same_subnet', 0, () => {
      // 两个接口同网段（wlan0/wlan1 均 192.168.1.x/24）→ 通配去重
      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi),
        makeIface('wlan1', '192.168.1.6', 24, NetworkType.wifi)
      ]
      let result = computeDiscoveryWhitelistFrom(['wlan0', 'wlan1'], [], interfaces)
      expect(result !== undefined).assertTrue()
      if (result !== undefined) {
        expect(result.length === 1).assertTrue()
        expect(result[0] === '192.168.1.*').assertTrue()
      }
    })

    it('whitelist_empty_returns_empty_list', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi)
      ]
      // 白名单为空 → 空列表（Rust 侧忽略全部接口，不扫描）
      let result = computeDiscoveryWhitelistFrom([], [], interfaces)
      expect(result.length === 0).assertTrue()
    })

    it('whitelist_no_match_returns_empty_list', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi)
      ]
      // 白名单接口名不匹配任何接口 → 空列表
      let result = computeDiscoveryWhitelistFrom(['eth0'], [], interfaces)
      expect(result.length === 0).assertTrue()
    })

    it('whitelist_all_blacklisted_returns_empty_list', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi)
      ]
      let result = computeDiscoveryWhitelistFrom(['wlan0'], ['wlan0'], interfaces)
      expect(result.length === 0).assertTrue()
    })

    // ── ensureDefaultNetworkLists 首次初始化 ──

    it('ensure_default_lists_wifi_ethernet_to_whitelist', 0, () => {
      // 记录并清空现有配置（模拟首次启动）
      let origW: string = getNetworkWhitelist()
      let origB: string = getNetworkBlacklist()
      setNetworkWhitelist('')
      setNetworkBlacklist('')

      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi),
        makeIface('eth0', '10.0.0.1', 16, NetworkType.ethernet),
        makeIface('rmnet0', '100.64.0.1', 32, NetworkType.cellular),
        makeIface('p2p0', '192.168.49.1', 24, NetworkType.unknown)
      ]
      ensureDefaultNetworkLists(interfaces)

      let whitelist: string = getNetworkWhitelist()
      let blacklist: string = getNetworkBlacklist()
      expect(whitelist.indexOf('wlan0') >= 0).assertTrue()
      expect(whitelist.indexOf('eth0') >= 0).assertTrue()
      expect(whitelist.indexOf('rmnet0') < 0).assertTrue()
      expect(blacklist.indexOf('rmnet0') >= 0).assertTrue()
      expect(blacklist.indexOf('p2p0') >= 0).assertTrue()

      // 恢复原配置
      setNetworkWhitelist(origW)
      setNetworkBlacklist(origB)
    })

    it('ensure_default_lists_does_not_overwrite_existing', 0, () => {
      let origW: string = getNetworkWhitelist()
      let origB: string = getNetworkBlacklist()
      // 已有配置（wlan0 白名单）
      setNetworkWhitelist('wlan0')
      setNetworkBlacklist('')

      let interfaces: Array<NetworkInterface> = [
        makeIface('wlan0', '192.168.1.5', 24, NetworkType.wifi),
        makeIface('eth0', '10.0.0.1', 16, NetworkType.ethernet)
      ]
      ensureDefaultNetworkLists(interfaces)

      // 已有配置不被覆盖（eth0 不应被自动加入）
      let whitelist: string = getNetworkWhitelist()
      expect(whitelist === 'wlan0').assertTrue()
      expect(whitelist.indexOf('eth0') < 0).assertTrue()

      setNetworkWhitelist(origW)
      setNetworkBlacklist(origB)
    })

    it('ensure_default_lists_empty_interfaces', 0, () => {
      let origW: string = getNetworkWhitelist()
      let origB: string = getNetworkBlacklist()
      setNetworkWhitelist('')
      setNetworkBlacklist('')

      // 无接口 → 白名单/黑名单均保持空
      ensureDefaultNetworkLists([])
      expect(getNetworkWhitelist() === '').assertTrue()
      expect(getNetworkBlacklist() === '').assertTrue()

      setNetworkWhitelist(origW)
      setNetworkBlacklist(origB)
    })
  })
}
