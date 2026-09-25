// ProtocolToggleSettingsTest：协议总开关（LocalSend / MTA）设置存储链测试
// 覆盖 SettingsRepository 两开关的默认值常量、读写与 loadFromPreferences 回读。
// 用例采用「记录-恢复」模式：结束后还原宿主应用的持久化设置，避免污染。
import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  getLocalSendEnabled,
  setLocalSendEnabled,
  getMtaEnabled,
  setMtaEnabled,
  loadFromPreferences
} from '../../../../main/ets/service/repository/SettingsRepository'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import {
  DEFAULT_LOCALSEND_ENABLED,
  DEFAULT_MTA_ENABLED
} from '../../../../main/ets/model/SettingsDefaults'
import { getTestAppContext } from '../helper/TestContext'

export default function ProtocolToggleSettingsTest() {
  describe('ProtocolToggleSettingsTest', () => {

    beforeAll(() => {
      // 初始化偏好存储（测试环境未走 App 主流程，preferences 未初始化）
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    // ── 默认值常量 ──

    it('toggle_defaults_are_both_enabled', 0, () => {
      expect(DEFAULT_LOCALSEND_ENABLED).assertTrue()
      expect(DEFAULT_MTA_ENABLED).assertTrue()
    })

    // ── LocalSend 总开关读写与回读 ──

    it('localsend_toggle_write_read_and_reload', 0, () => {
      let orig: boolean = getLocalSendEnabled()
      try {
        setLocalSendEnabled(false)
        expect(getLocalSendEnabled()).assertFalse()
        // 持久化后经 loadFromPreferences 回读仍为关闭
        loadFromPreferences()
        expect(getLocalSendEnabled()).assertFalse()

        setLocalSendEnabled(true)
        expect(getLocalSendEnabled()).assertTrue()
        loadFromPreferences()
        expect(getLocalSendEnabled()).assertTrue()
      } finally {
        // 恢复原开关状态，避免污染宿主应用设置
        setLocalSendEnabled(orig)
        loadFromPreferences()
      }
    })

    // ── MTA 总开关读写与回读 ──

    it('mta_toggle_write_read_and_reload', 0, () => {
      let orig: boolean = getMtaEnabled()
      try {
        setMtaEnabled(false)
        expect(getMtaEnabled()).assertFalse()
        // 持久化后经 loadFromPreferences 回读仍为关闭
        loadFromPreferences()
        expect(getMtaEnabled()).assertFalse()

        setMtaEnabled(true)
        expect(getMtaEnabled()).assertTrue()
        loadFromPreferences()
        expect(getMtaEnabled()).assertTrue()
      } finally {
        // 恢复原开关状态，避免污染宿主应用设置
        setMtaEnabled(orig)
        loadFromPreferences()
      }
    })
  })
}
