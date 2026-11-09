import { describe, it, beforeAll, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { getTestAppContext } from '../helper/TestContext'
import { setAppContext } from '../../../../main/ets/service/repository/AppCore'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import {
  collectActiveTempKeepSet,
  sweepTempWorkspaceDir
} from '../../../../main/ets/service/transfer/TempWorkspaceSweep'
import {
  SESSION_DRAFT_SCHEMA_VERSION,
  SessionDraft,
  SessionDraftFile,
  removeSessionDraft,
  saveSessionDraft
} from '../../../../main/ets/service/transfer/SessionDraftStore'
import {
  createSession,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionDataFlow,
  SessionFileStage,
  SessionInitiator,
  SessionStage
} from '../../../../main/ets/model/transfer/TransferSession'

function writeText(path: string, content: string): void {
  let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  fs.writeSync(file.fd, content)
  fs.closeSync(file)
}

function makeDraft(sessionId: string, finalPath: string, tempPath: string): SessionDraft {
  let file: SessionDraftFile = {
    fileId: 'f1',
    fileName: 'active.bin',
    fileType: '',
    totalBytes: 8,
    occurrence: 1,
    checksum: '',
    finalPath: finalPath,
    tempPath: tempPath,
    stage: SessionFileStage.transferring,
    bytesSent: 0,
    completedAt: 0,
    isTextMessage: false
  }
  let draft: SessionDraft = {
    schemaVersion: SESSION_DRAFT_SCHEMA_VERSION,
    sessionId: sessionId,
    protocolKey: 'test-sweep',
    protocolSessionId: sessionId,
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    stage: SessionStage.active,
    textMessage: false,
    peer: {
      displayName: 'sweep-tester',
      badges: []
    },
    localAlias: '',
    localIp: '',
    localInterfaceName: '',
    startedAt: Date.now(),
    transferStartedAt: 0,
    updatedAt: Date.now(),
    files: [file]
  }
  return draft
}

export default function TempWorkspaceSweepTest() {
  describe('TempWorkspaceSweepTest', () => {
    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        setAppContext(ctx)
        initAllPreferences(ctx)
      }
    })

    it('sweep_removes_all_protocol_and_legacy_temp', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      let root = ctx.filesDir + '/sweep-all-' + Date.now().toString()
      let temp = root + '/.handysend-temp'
      let local = temp + '/localsend'
      let legacySub = temp + '/local-send'
      let mta = temp + '/mta'
      let web = temp + '/web'
      let legacyDir = root + '/.handysend-upload-part'
      fs.mkdirSync(local, true)
      fs.mkdirSync(legacySub, true)
      fs.mkdirSync(mta, true)
      fs.mkdirSync(web, true)
      fs.mkdirSync(legacyDir, true)
      writeText(local + '/a.bin', 'a')
      writeText(legacySub + '/b.bin', 'b')
      writeText(mta + '/c.bin', 'c')
      writeText(web + '/d.bin', 'd')
      writeText(temp + '/root.bin', 'r')
      writeText(legacyDir + '/e.bin', 'e')
      writeText(root + '/user.txt', 'keep')

      let removed = sweepTempWorkspaceDir(root, new Set<string>())

      expect(removed).assertEqual(6)
      expect(fs.accessSync(temp)).assertFalse()
      expect(fs.accessSync(legacyDir)).assertFalse()
      expect(fs.accessSync(root + '/user.txt')).assertTrue()
      fs.unlinkSync(root + '/user.txt')
      fs.rmdirSync(root)
    })

    it('sweep_keeps_active_session_temp', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      let root = ctx.filesDir + '/sweep-keep-' + Date.now().toString()
      let tempDir = root + '/.handysend-temp/localsend'
      fs.mkdirSync(tempDir, true)
      let tempPath = tempDir + '/active.bin'
      writeText(tempPath, 'inflight')
      let session = createSession({
        protocolKey: 'test-sweep-active',
        protocolSessionId: '',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: {
          displayName: 'peer',
          badges: []
        },
        files: [{
          fileId: 'f1',
          fileName: 'active.bin',
          fileType: '',
          totalBytes: 8,
          path: root + '/active.bin'
        }],
        capabilities: {
          canCancel: true,
          canRetry: false,
          needsConfirm: false,
          hasByteProgress: true,
          canSaveToGallery: false,
          hasVerify: false
        }
      })
      let draft = makeDraft(session.id, root + '/active.bin', tempPath)
      saveSessionDraft(draft)

      let keep = collectActiveTempKeepSet([draft])
      sweepTempWorkspaceDir(root, keep)

      expect(fs.accessSync(tempPath)).assertTrue()
      removeSessionDraft(session.id)
      resetRegistry()
      fs.rmdirSync(root)
    })
  })
}
