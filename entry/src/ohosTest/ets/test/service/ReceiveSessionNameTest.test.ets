// ReceiveSessionNameTest：接收目标确定后回写会话文件显示名
// 详情页的文件名来自创建时的描述符；prepareRecvTargets 确定最终相对名后，
// 需要 updateSessionFileName 把实际名（含目录前缀/去重后缀）同步回会话。
import { describe, it, expect } from '@ohos/hypium'
import {
  createSession,
  finish,
  getSession,
  resetRegistry,
  updateSessionFileName,
  updateSessionFileTargets
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionCapabilities,
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  SessionStage
} from '../../../../main/ets/model/transfer/TransferSession'
import { LOCAL_RECEIVE_KEY } from '../../../../main/ets/service/transfer/adapters/LocalSendReceiveAdapter'

function testCapabilities(): SessionCapabilities {
  return {
    canCancel: true,
    canRetry: false,
    needsConfirm: true,
    hasByteProgress: true,
    canSaveToGallery: true,
    hasVerify: true
  }
}

export default function ReceiveSessionNameTest() {
  describe('ReceiveSessionNameTest', () => {
    it('updates_visible_name_and_rejects_terminal', 0, () => {
      resetRegistry()
      let input: SessionCreateInput = {
        protocolKey: LOCAL_RECEIVE_KEY,
        protocolSessionId: 'name-test-1',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: { displayName: 'NameTest', badges: [] },
        files: [{
          fileId: 'f1',
          fileName: 'Photos/2024/a.jpg',
          fileType: 'image/jpeg',
          totalBytes: 1
        }],
        capabilities: testCapabilities(),
        stage: SessionStage.active
      }
      let session = createSession(input)
      expect(updateSessionFileName(session.id, 'f1', 'Photos/2024/a (1).jpg')).assertTrue()
      let updated = getSession(session.id)
      expect(updated !== undefined).assertTrue()
      if (updated !== undefined) {
        expect(updated.files[0].fileName).assertEqual('Photos/2024/a (1).jpg')
      }
      finish(session.id, SessionStage.succeeded)
      // 终态后不再改写显示名
      expect(updateSessionFileName(session.id, 'f1', 'Photos/2024/a (2).jpg')).assertFalse()
      let terminal = getSession(session.id)
      if (terminal !== undefined) {
        expect(terminal.files[0].fileName).assertEqual('Photos/2024/a (1).jpg')
      }
      resetRegistry()
    })

    it('batch_updates_paths_and_names_once', 0, () => {
      resetRegistry()
      let input: SessionCreateInput = {
        protocolKey: LOCAL_RECEIVE_KEY,
        protocolSessionId: 'name-test-2',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: { displayName: 'NameTest', badges: [] },
        files: [{
          fileId: 'f1',
          fileName: 'Photos/a.jpg',
          fileType: 'image/jpeg',
          totalBytes: 1
        }, {
          fileId: 'f2',
          fileName: 'Photos/b.jpg',
          fileType: 'image/jpeg',
          totalBytes: 1
        }],
        capabilities: testCapabilities(),
        stage: SessionStage.active
      }
      let session = createSession(input)
      let paths: Record<string, string> = {
        'f1': '/tmp/Photos/a (1).jpg',
        'f2': '/tmp/Photos/b.jpg'
      }
      let names: Record<string, string> = {
        'f1': 'Photos/a (1).jpg',
        'f2': 'Photos/b.jpg'
      }
      expect(updateSessionFileTargets(session.id, paths, names)).assertTrue()
      let updated = getSession(session.id)
      expect(updated !== undefined).assertTrue()
      if (updated !== undefined) {
        expect(updated.files[0].path).assertEqual('/tmp/Photos/a (1).jpg')
        expect(updated.files[0].fileName).assertEqual('Photos/a (1).jpg')
        expect(updated.files[1].path).assertEqual('/tmp/Photos/b.jpg')
        expect(updated.files[1].fileName).assertEqual('Photos/b.jpg')
      }
      finish(session.id, SessionStage.succeeded)
      expect(updateSessionFileTargets(session.id, paths, names)).assertFalse()
      resetRegistry()
    })
  })
}
