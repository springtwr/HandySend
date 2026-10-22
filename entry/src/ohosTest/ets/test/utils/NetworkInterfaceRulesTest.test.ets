// NetworkInterfaceRules 纯函数测试：
// 接口名类型推断、白/黑名单默认启用策略
import { describe, it, expect } from '@ohos/hypium'
import { NetworkType } from '../../../../main/ets/model/Types'
import {
  networkTypeFromName,
  isEnabledByDefault,
  isInterfaceEnabled
} from '../../../../main/ets/utils/NetworkInterfaceRules'

export default function NetworkInterfaceRulesTest() {
  describe('NetworkInterfaceRulesTest', () => {
    // ── networkTypeFromName ──

    it('networkTypeFromName_wifi', 0, () => {
      expect(networkTypeFromName('wlan0') === NetworkType.wifi).assertTrue()
      // SoftAP 与 Wi-Fi Direct 同属无线接口
      expect(networkTypeFromName('wlan1') === NetworkType.wifi).assertTrue()
      expect(networkTypeFromName('wifi_eth') === NetworkType.wifi).assertTrue()
      expect(networkTypeFromName('p2p0') === NetworkType.wifi).assertTrue()
      expect(networkTypeFromName('ap0') === NetworkType.wifi).assertTrue()
    })

    it('networkTypeFromName_ethernet', 0, () => {
      expect(networkTypeFromName('eth0') === NetworkType.ethernet).assertTrue()
      expect(networkTypeFromName('usb0') === NetworkType.ethernet).assertTrue()
      expect(networkTypeFromName('enp0s3') === NetworkType.ethernet).assertTrue()
    })

    it('networkTypeFromName_cellular', 0, () => {
      expect(networkTypeFromName('rmnet0') === NetworkType.cellular).assertTrue()
      expect(networkTypeFromName('ccmni0') === NetworkType.cellular).assertTrue()
      expect(networkTypeFromName('wwan0') === NetworkType.cellular).assertTrue()
    })

    it('networkTypeFromName_vpn', 0, () => {
      expect(networkTypeFromName('tun0') === NetworkType.vpn).assertTrue()
      expect(networkTypeFromName('tap0') === NetworkType.vpn).assertTrue()
      expect(networkTypeFromName('wg0') === NetworkType.vpn).assertTrue()
      expect(networkTypeFromName('zt0') === NetworkType.vpn).assertTrue()
      expect(networkTypeFromName('tailscale0') === NetworkType.vpn).assertTrue()
      expect(networkTypeFromName('easytier0') === NetworkType.vpn).assertTrue()
    })

    it('networkTypeFromName_containerBridge', 0, () => {
      // 容器网桥判定先于无线前缀：anco-wlan1 不应被判为 wifi
      expect(networkTypeFromName('ancowlan0') === NetworkType.bridge).assertTrue()
      expect(networkTypeFromName('anco-wlan1') === NetworkType.bridge).assertTrue()
      expect(networkTypeFromName('docker0') === NetworkType.bridge).assertTrue()
    })

    it('networkTypeFromName_unknownFallback', 0, () => {
      expect(networkTypeFromName('') === NetworkType.unknown).assertTrue()
      expect(networkTypeFromName('foo0') === NetworkType.unknown).assertTrue()
    })

    // ── isEnabledByDefault ──

    it('isEnabledByDefault_byType', 0, () => {
      expect(isEnabledByDefault(NetworkType.wifi)).assertTrue()
      expect(isEnabledByDefault(NetworkType.ethernet)).assertTrue()
      // 虚拟组网是跨网传输的主要通道，默认放行
      expect(isEnabledByDefault(NetworkType.vpn)).assertTrue()
      expect(isEnabledByDefault(NetworkType.bridge)).assertFalse()
      expect(isEnabledByDefault(NetworkType.cellular)).assertFalse()
      expect(isEnabledByDefault(NetworkType.unknown)).assertFalse()
    })

    // ── isInterfaceEnabled ──

    it('isInterfaceEnabled_blacklistFirst', 0, () => {
      expect(isInterfaceEnabled('wlan0', NetworkType.wifi, ['wlan0'], [])).assertTrue()
      expect(isInterfaceEnabled('wlan0', NetworkType.wifi, ['wlan0'], ['wlan0'])).assertFalse()
      expect(isInterfaceEnabled('wlan0', NetworkType.wifi, [], ['wlan0'])).assertFalse()
    })

    it('isInterfaceEnabled_defaultFallback', 0, () => {
      expect(isInterfaceEnabled('wlan1', NetworkType.wifi, [], [])).assertTrue()
      expect(isInterfaceEnabled('tun0', NetworkType.vpn, [], [])).assertTrue()
      expect(isInterfaceEnabled('ancowlan0', NetworkType.bridge, [], [])).assertFalse()
      expect(isInterfaceEnabled('rmnet0', NetworkType.cellular, [], [])).assertFalse()
    })

    it('isInterfaceEnabled_whitelistOverridesDefaultOff', 0, () => {
      // 默认关闭的类型经用户显式放行后可启用
      expect(isInterfaceEnabled('rmnet0', NetworkType.cellular, ['rmnet0'], [])).assertTrue()
      expect(isInterfaceEnabled('ancowlan0', NetworkType.bridge, ['ancowlan0'], [])).assertTrue()
    })
  })
}
