import { describe, it, expect } from '@ohos/hypium'
import {
  computePendingReasons,
  diffServerRunConfig,
  isAliasOnlyPending,
  isAliasPending,
  ServerPendingReason,
  ServerRunConfig
} from '../../../../main/ets/model/ServerRunConfig'

function baseConfig(): ServerRunConfig {
  return {
    alias: 'Phone A',
    deviceType: 'mobile',
    deviceModel: 'Model A',
    port: 53317,
    useHttps: true,
    pin: '',
    multicastGroup: '224.0.0.167',
    discoveryTimeout: 500
  }
}

export default function ServerRunConfigTest() {
  describe('ServerRunConfigTest', () => {
    it('no_snapshot_has_no_pending', 0, () => {
      expect(computePendingReasons(undefined, baseConfig()).length).assertEqual(0)
    })

    it('alias_change_is_alias_only', 0, () => {
      let current: ServerRunConfig = baseConfig()
      current.alias = 'Phone B'
      let reasons = diffServerRunConfig(baseConfig(), current)
      expect(reasons.length).assertEqual(1)
      expect(reasons[0]).assertEqual(ServerPendingReason.alias)
      expect(isAliasOnlyPending(reasons)).assertTrue()
      expect(isAliasPending(reasons)).assertTrue()
    })

    it('revert_alias_clears_pending', 0, () => {
      let current: ServerRunConfig = baseConfig()
      current.alias = 'Phone A'
      expect(diffServerRunConfig(baseConfig(), current).length).assertEqual(0)
    })

    it('port_only_is_not_alias_only', 0, () => {
      let current: ServerRunConfig = baseConfig()
      current.port = 53318
      let reasons = diffServerRunConfig(baseConfig(), current)
      expect(reasons.length).assertEqual(1)
      expect(reasons[0]).assertEqual(ServerPendingReason.port)
      expect(isAliasOnlyPending(reasons)).assertFalse()
      expect(isAliasPending(reasons)).assertFalse()
    })

    it('alias_plus_port_has_two_reasons', 0, () => {
      let current: ServerRunConfig = baseConfig()
      current.alias = 'Phone B'
      current.port = 53318
      let reasons = diffServerRunConfig(baseConfig(), current)
      expect(reasons.length).assertEqual(2)
      expect(isAliasOnlyPending(reasons)).assertFalse()
      expect(isAliasPending(reasons)).assertTrue()
    })

    it('same_config_has_no_pending', 0, () => {
      expect(diffServerRunConfig(baseConfig(), baseConfig()).length).assertEqual(0)
    })
  })
}
