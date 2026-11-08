import { describe, it, beforeAll, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { getTestAppContext } from '../helper/TestContext'
import { setAppContext } from '../../../../main/ets/service/repository/AppCore'
import {
  SESSION_DRAFT_SCHEMA_VERSION,
  SessionDraft,
  SessionDraftFile,
  cleanupSessionDraftTmp,
  loadAllSessionDrafts,
  loadSessionDraft,
  removeSessionDraft,
  sanitizeDraftId,
  saveSessionDraft,
  sessionDraftDir
} from '../../../../main/ets/service/transfer/SessionDraftStore'
import {
  baseNameOf,
  dirNameOf,
  tempDirForFinal,
  tempPathForFinal
} from '../../../../main/ets/model/transfer/TransferTempPaths'
import {
  SessionDataFlow,
  SessionFileStage,
  SessionInitiator,
  SessionStage
} from '../../../../main/ets/model/transfer/TransferSession'

function makeFile(fileId: string, finalPath: string): SessionDraftFile {
  let file: SessionDraftFile = {
    fileId: fileId,
    fileName: 'a.txt',
    fileType: 'text/plain',
    totalBytes: 3,
    occurrence: 1,
    checksum: '',
    finalPath: finalPath,
    tempPath: '',
    stage: SessionFileStage.waiting,
    bytesSent: 0,
    completedAt: 0,
    isTextMessage: false
  }
  return file
}

function makeDraft(sessionId: string, files: Array<SessionDraftFile>): SessionDraft {
  let draft: SessionDraft = {
    schemaVersion: SESSION_DRAFT_SCHEMA_VERSION,
    sessionId: sessionId,
    protocolKey: 'web-upload',
    protocolSessionId: sessionId,
    dataFlow: SessionDataFlow.inbound,
    initiatedBy: SessionInitiator.remote,
    stage: SessionStage.active,
    textMessage: false,
    peer: {
      displayName: 'tester',
      badges: []
    },
    localAlias: '',
    localIp: '',
    localInterfaceName: '',
    startedAt: Date.now() - 1000,
    transferStartedAt: 0,
    updatedAt: Date.now(),
    files: files
  }
  return draft
}

export default function SessionDraftStoreTest() {
  describe('SessionDraftStoreTest', () => {
    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        setAppContext(ctx)
      }
    })

    it('sanitizeDraftId_keeps_safe_chars', 0, () => {
      expect(sanitizeDraftId('web-upload_1.2')).assertEqual('web-upload_1.2')
      expect(sanitizeDraftId('a/b:c')).assertEqual('a_b_c')
      expect(sanitizeDraftId('')).assertEqual('session')
    })

    it('save_load_remove_roundtrip', 0, () => {
      let id = 'draft-roundtrip-' + Date.now().toString()
      let draft = makeDraft(id, [makeFile('f1', '/tmp/a.txt')])
      expect(saveSessionDraft(draft)).assertTrue()
      let loaded = loadSessionDraft(id)
      expect(loaded !== undefined).assertTrue()
      if (loaded !== undefined) {
        expect(loaded.sessionId).assertEqual(id)
        expect(loaded.files.length).assertEqual(1)
        expect(loaded.files[0].fileId).assertEqual('f1')
      }
      removeSessionDraft(id)
      expect(loadSessionDraft(id) === undefined).assertTrue()
    })

    it('cleanup_removes_tmp_file', 0, () => {
      let dir = sessionDraftDir()
      expect(dir.length > 0).assertTrue()
      if (dir.length === 0) {
        return
      }
      let tmp = dir + '/draft-tmp-test.json.tmp'
      let file = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, '{}')
      fs.closeSync(file)
      cleanupSessionDraftTmp()
      expect(fs.accessSync(tmp)).assertFalse()
    })

    it('save_overwrites_existing_draft', 0, () => {
      let id = 'draft-overwrite-' + Date.now().toString()
      let draft = makeDraft(id, [makeFile('f1', '/tmp/a.txt')])
      expect(saveSessionDraft(draft)).assertTrue()
      draft.updatedAt = 12345678
      expect(saveSessionDraft(draft)).assertTrue()
      let loaded = loadSessionDraft(id)
      expect(loaded !== undefined).assertTrue()
      if (loaded !== undefined) {
        expect(loaded.updatedAt).assertEqual(12345678)
      }
      removeSessionDraft(id)
    })

    it('temp_path_matches_final_path', 0, () => {
      expect(tempDirForFinal('/a/b/c.txt')).assertEqual('/a/b/.handysend-temp')
      expect(tempPathForFinal('/a/b/c.txt')).assertEqual('/a/b/.handysend-temp/c.txt')
      expect(baseNameOf('/a/b/c.txt')).assertEqual('c.txt')
      expect(dirNameOf('/a/b/c.txt')).assertEqual('/a/b')
    })

    it('loadAll_returns_saved_drafts', 0, () => {
      let idA = 'draft-all-a-' + Date.now().toString()
      let idB = 'draft-all-b-' + Date.now().toString()
      expect(saveSessionDraft(makeDraft(idA, []))).assertTrue()
      expect(saveSessionDraft(makeDraft(idB, []))).assertTrue()
      let drafts = loadAllSessionDrafts()
      let foundA = false
      let foundB = false
      for (let i = 0; i < drafts.length; i++) {
        if (drafts[i].sessionId === idA) {
          foundA = true
        }
        if (drafts[i].sessionId === idB) {
          foundB = true
        }
      }
      expect(foundA).assertTrue()
      expect(foundB).assertTrue()
      removeSessionDraft(idA)
      removeSessionDraft(idB)
    })
  })
}
