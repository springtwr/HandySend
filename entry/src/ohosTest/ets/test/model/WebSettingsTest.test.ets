// WebSettingsTest：网页独立设置项（加密/端口/接口白黑名单）的默认值、读写与一次性迁移
// 用例采用「记录-恢复」模式：结束后还原宿主应用的持久化设置，避免污染。
import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  getWebHttpsEnabled,
  setWebHttpsEnabled,
  getWebPort,
  setWebPort,
  getWebLastPort,
  setWebLastPort,
  getWebInterfaceNames,
  getWebInterfaceBlacklistNames,
  setWebInterfaces,
  loadFromPreferences
} from '../../../../main/ets/service/repository/SettingsRepository'
import {
  DEFAULT_WEB_HTTPS_ENABLED,
  DEFAULT_WEB_LAST_PORT,
  DEFAULT_WEB_PORT
} from '../../../../main/ets/model/SettingsDefaults'
import {
  initAllPreferences,
  preferencesUtil,
  KEY_ENCRYPTED_TRANSFER,
  KEY_RECEIVE_PIN,
  KEY_WEB_HTTPS_ENABLED
} from '../../../../main/ets/utils/PreferencesUtil'
import { getTestAppContext } from '../helper/TestContext'

export default function WebSettingsTest() {
  describe('WebSettingsTest', () => {

    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        initAllPreferences(ctx)
      }
    })

    it('defaults_are_off_and_53310', 0, () => {
      expect(DEFAULT_WEB_HTTPS_ENABLED).assertFalse()
      expect(DEFAULT_WEB_PORT).assertEqual(53310)
    })

    it('web_settings_write_read_and_reload', 0, () => {
      let origHttps: boolean = getWebHttpsEnabled()
      let origPort: number = getWebPort()
      let origLastPort: number = getWebLastPort()
      let origInterfaces: Array<string> = getWebInterfaceNames()
      let origBlacklist: Array<string> = getWebInterfaceBlacklistNames()
      try {
        setWebHttpsEnabled(true)
        setWebPort(53316)
        setWebInterfaces(['wlan0'], ['eth0'])
        loadFromPreferences()
        expect(getWebHttpsEnabled()).assertTrue()
        expect(getWebPort()).assertEqual(53316)
        expect(getWebInterfaceNames().length).assertEqual(1)
        expect(getWebInterfaceNames()[0]).assertEqual('wlan0')
        expect(getWebInterfaceBlacklistNames().length).assertEqual(1)
        expect(getWebInterfaceBlacklistNames()[0]).assertEqual('eth0')
      } finally {
        setWebHttpsEnabled(origHttps)
        setWebPort(origPort)
        setWebInterfaces(origInterfaces, origBlacklist)
        loadFromPreferences()
        setWebLastPort(origLastPort)
      }
    })

    it('last_actual_port_is_not_restored_on_reload', 0, () => {
      let origLastPort: number = getWebLastPort()
      try {
        // 回退得到的临时端口只在本次进程内复用；重新加载设置后回到“未记录”，
        // 下次启动仍先尝试配置端口
        setWebLastPort(40123)
        expect(getWebLastPort()).assertEqual(40123)
        loadFromPreferences()
        expect(getWebLastPort()).assertEqual(DEFAULT_WEB_LAST_PORT)
      } finally {
        setWebLastPort(origLastPort)
      }
    })

    it('migrates_https_from_localsend_once_when_keys_absent', 0, () => {
      let origHttps: boolean = getWebHttpsEnabled()
      let origLocalHttps: boolean = preferencesUtil.getBoolean(KEY_ENCRYPTED_TRANSFER, false)
      let origLocalPin: string = preferencesUtil.getString(KEY_RECEIVE_PIN, '')
      try {
        // 模拟升级前：网页加密键不存在，LocalSend 已有加密与 PIN
        preferencesUtil.delete(KEY_WEB_HTTPS_ENABLED)
        preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, true)
        preferencesUtil.setString(KEY_RECEIVE_PIN, '9999')
        loadFromPreferences()
        expect(getWebHttpsEnabled()).assertTrue()

        // 之后修改 LocalSend 值不应再影响网页
        preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, false)
        preferencesUtil.setString(KEY_RECEIVE_PIN, '1111')
        loadFromPreferences()
        expect(getWebHttpsEnabled()).assertTrue()
      } finally {
        preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, origLocalHttps)
        preferencesUtil.setString(KEY_RECEIVE_PIN, origLocalPin)
        setWebHttpsEnabled(origHttps)
        loadFromPreferences()
      }
    })
  })
}
