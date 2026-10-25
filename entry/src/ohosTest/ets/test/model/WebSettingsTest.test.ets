// WebSettingsTest：网页独立设置项（加密/PIN/端口/网卡）的默认值、读写与一次性迁移
// 用例采用「记录-恢复」模式：结束后还原宿主应用的持久化设置，避免污染。
import { describe, it, expect, beforeAll } from '@ohos/hypium'
import {
  getWebHttpsEnabled,
  setWebHttpsEnabled,
  getWebPin,
  setWebPin,
  getWebPort,
  setWebPort,
  getWebLastPort,
  setWebLastPort,
  getWebInterfaceNames,
  setWebInterfaces,
  loadFromPreferences
} from '../../../../main/ets/service/repository/SettingsRepository'
import {
  DEFAULT_WEB_HTTPS_ENABLED,
  DEFAULT_WEB_PIN,
  DEFAULT_WEB_PORT
} from '../../../../main/ets/model/SettingsDefaults'
import {
  initAllPreferences,
  preferencesUtil,
  KEY_ENCRYPTED_TRANSFER,
  KEY_RECEIVE_PIN,
  KEY_WEB_HTTPS_ENABLED,
  KEY_WEB_PIN
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

    it('defaults_are_off_empty_and_53310', 0, () => {
      expect(DEFAULT_WEB_HTTPS_ENABLED).assertFalse()
      expect(DEFAULT_WEB_PIN).assertEqual('')
      expect(DEFAULT_WEB_PORT).assertEqual(53310)
    })

    it('web_settings_write_read_and_reload', 0, () => {
      let origHttps: boolean = getWebHttpsEnabled()
      let origPin: string = getWebPin()
      let origPort: number = getWebPort()
      let origLastPort: number = getWebLastPort()
      let origInterfaces: Array<string> = getWebInterfaceNames()
      try {
        setWebHttpsEnabled(true)
        setWebPin('1234')
        setWebPort(53316)
        setWebInterfaces(['wlan0', 'eth0'])
        loadFromPreferences()
        expect(getWebHttpsEnabled()).assertTrue()
        expect(getWebPin()).assertEqual('1234')
        expect(getWebPort()).assertEqual(53316)
        expect(getWebInterfaceNames().length).assertEqual(2)
        expect(getWebInterfaceNames()[0]).assertEqual('wlan0')
      } finally {
        setWebHttpsEnabled(origHttps)
        setWebPin(origPin)
        setWebPort(origPort)
        setWebLastPort(origLastPort)
        setWebInterfaces(origInterfaces)
        loadFromPreferences()
      }
    })

    it('migrates_from_localsend_once_when_keys_absent', 0, () => {
      let origHttps: boolean = getWebHttpsEnabled()
      let origPin: string = getWebPin()
      let origLocalHttps: boolean = preferencesUtil.getBoolean(KEY_ENCRYPTED_TRANSFER, false)
      let origLocalPin: string = preferencesUtil.getString(KEY_RECEIVE_PIN, '')
      try {
        // 模拟升级前：网页键不存在，LocalSend 已有加密与 PIN
        preferencesUtil.delete(KEY_WEB_HTTPS_ENABLED)
        preferencesUtil.delete(KEY_WEB_PIN)
        preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, true)
        preferencesUtil.setString(KEY_RECEIVE_PIN, '9999')
        loadFromPreferences()
        expect(getWebHttpsEnabled()).assertTrue()
        expect(getWebPin()).assertEqual('9999')

        // 之后修改 LocalSend 值不应再影响网页
        preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, false)
        preferencesUtil.setString(KEY_RECEIVE_PIN, '1111')
        loadFromPreferences()
        expect(getWebHttpsEnabled()).assertTrue()
        expect(getWebPin()).assertEqual('9999')
      } finally {
        // 恢复原始 LocalSend 与网页值（显式写入网页值，避免再次触发迁移）
        preferencesUtil.setBoolean(KEY_ENCRYPTED_TRANSFER, origLocalHttps)
        preferencesUtil.setString(KEY_RECEIVE_PIN, origLocalPin)
        setWebHttpsEnabled(origHttps)
        setWebPin(origPin)
        loadFromPreferences()
      }
    })
  })
}
