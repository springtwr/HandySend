import { describe, it, expect } from '@ohos/hypium'
import {
  SessionStage
} from '../../../../main/ets/model/transfer/TransferSession'
import {
  beginStubSession,
  advanceStubSession,
  finishStubSession,
  registerStubProtocol,
  STUB_KEY
} from '../../../../main/ets/service/transfer/adapters/StubAdapter'
import {
  cancel,
  getAllSessions,
  getOverallSnapshot,
  getSessionCapabilities,
  resetRegistry,
  getSession
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import { getAdapter } from '../../../../main/ets/service/transfer/adapters/SessionAdapter'
import { getSource, listSources } from '../../../../main/ets/service/transfer/DeviceSourceRegistry'
import { listSettingsGroups } from '../../../../main/ets/service/transfer/SettingsGroupRegistry'
import { SessionDetailViewModel } from '../../../../main/ets/viewmodel/SessionDetailViewModel'
import { collectActiveSessionIds } from '../../../../main/ets/viewmodel/TransferCenterViewModel'

export default function AdapterExtensibilityTest() {
  describe('AdapterExtensibilityTest', () => {
    it('stub_onlyDescriptorAndAdapter_visibleEverywhere', 0, () => {
      resetRegistry()
      registerStubProtocol()
      // 新协议的会话无需改动引擎即出现在统一注册表
      let id = beginStubSession('Stub peer', '握手中')
      let all = getAllSessions()
      expect(all.length).assertEqual(1)
      expect(all[0].protocolKey).assertEqual(STUB_KEY)
      // 参与协议无关聚合
      let overall = getOverallSnapshot(0)
      expect(overall.active).assertTrue()
      expect(overall.sessionCount).assertEqual(1)
      // 来源描述符与设置分组已注册（发送页/设置页零改动即可渲染）
      expect(getSource(STUB_KEY) !== undefined).assertTrue()
      expect(listSources().length > 0).assertTrue()
      let hasStubGroup: boolean = false
      let groups = listSettingsGroups()
      for (let i = 0; i < groups.length; i++) {
        if (groups[i].key === STUB_KEY) {
          hasStubGroup = true;
        }
      }
      expect(hasStubGroup).assertTrue()
      expect(id.length > 0).assertTrue()
      resetRegistry()
    })

    it('stub_capabilities_and_display_fromAdapter', 0, () => {
      resetRegistry()
      registerStubProtocol()
      let id = beginStubSession('Stub peer', '握手中')
      let session = getSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        let caps = getSessionCapabilities(session)
        expect(caps.canCancel).assertTrue()
        expect(caps.hasByteProgress).assertFalse()
      }
      let adapter = getAdapter(STUB_KEY)
      expect(adapter !== undefined).assertTrue()
      if (adapter !== undefined) {
        let descriptor = adapter.getDisplayDescriptor(id)
        expect(descriptor.peerTitle).assertEqual('Stub peer')
      }
      // 通用详情页仅凭适配器描述符即可渲染
      let vm = new SessionDetailViewModel()
      vm.load(id)
      expect(vm.display.peerTitle).assertEqual('Stub peer')
      expect(vm.canCancel()).assertTrue()
      expect(vm.hasByteProgress()).assertFalse()
      // 离散阶段文案透传
      advanceStubSession(id, '校验中')
      vm.refresh()
      expect(vm.session !== undefined).assertTrue()
      if (vm.session !== undefined) {
        expect(vm.session.stageText).assertEqual('校验中')
      }
      vm.unload()
      resetRegistry()
    })

    it('stub_cancel_viaUnifiedEntry', 0, () => {
      resetRegistry()
      registerStubProtocol()
      let id = beginStubSession('Stub peer', '握手中')
      cancel(id)
      let session = getSession(id)
      if (session !== undefined) {
        expect(session.stage).assertEqual(SessionStage.cancelled)
      }
      // 取消后不参与活跃集合
      expect(collectActiveSessionIds(getAllSessions()).length).assertEqual(0)
      resetRegistry()
    })

    it('stub_finish_participatesInAggregate', 0, () => {
      resetRegistry()
      registerStubProtocol()
      let id = beginStubSession('Stub peer', '握手中')
      finishStubSession(id, true)
      let overall = getOverallSnapshot(0)
      expect(overall.active).assertFalse()
      expect(overall.allFinished).assertTrue()
      expect(overall.hasFailure).assertFalse()
      resetRegistry()
    })
  })
}
