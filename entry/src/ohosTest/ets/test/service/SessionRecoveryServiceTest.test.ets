import { describe, it, beforeAll, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { getTestAppContext } from '../helper/TestContext'
import { setAppContext } from '../../../../main/ets/service/repository/AppCore'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import {
  clearAll,
  getHistory,
  initHistory
} from '../../../../main/ets/service/repository/ReceiveHistoryService'
import {
  clearSessionHistory,
  getSessionHistory
} from '../../../../main/ets/service/transfer/SessionHistoryStore'
import {
  SESSION_DRAFT_SCHEMA_VERSION,
  SessionDraft,
  SessionDraftFile,
  loadSessionDraft,
  saveSessionDraft,
  sessionDraftDir
} from '../../../../main/ets/service/transfer/SessionDraftStore'
import {
  SessionDataFlow,
  SessionFileStage,
  SessionHistoryOutcome,
  SessionInitiator,
  SessionStage
} from '../../../../main/ets/model/transfer/TransferSession'
import { recoverSessionDrafts } from '../../../../main/ets/service/transfer/SessionRecoveryService'

function makeFile(fileId: string, finalPath: string, totalBytes: number,
  tempPath?: string): SessionDraftFile {
  let file: SessionDraftFile = {
    fileId: fileId,
    fileName: 'a.txt',
    fileType: 'text/plain',
    totalBytes: totalBytes,
    occurrence: 1,
    checksum: '',
    finalPath: finalPath,
    tempPath: tempPath !== undefined ? tempPath : '',
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
      displayName: 'recovery-tester',
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

function writeText(path: string, content: string): void {
  let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  fs.writeSync(file.fd, content)
  fs.closeSync(file)
}

function clearDrafts(): void {
  let dir = sessionDraftDir()
  if (dir.length === 0) {
    return
  }
  try {
    let names = fs.listFileSync(dir)
    for (let i = 0; i < names.length; i++) {
      try {
        fs.unlinkSync(dir + '/' + names[i])
      } catch (_e) {
      }
    }
  } catch (_e) {
  }
}

function findSession(sessionId: string) {
  let all = getSessionHistory()
  for (let i = 0; i < all.length; i++) {
    if (all[i].sessionId === sessionId) {
      return all[i]
    }
  }
  return undefined
}

export default function SessionRecoveryServiceTest() {
  describe('SessionRecoveryServiceTest', () => {
    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        setAppContext(ctx)
        initAllPreferences(ctx)
        initHistory(ctx)
      }
    })

    it('recover_completed_draft_writes_task_and_receive_history', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-done-' + Date.now().toString()
      let finalPath = ctx.filesDir + '/' + id + '.txt'
      writeText(finalPath, 'abc')
      saveSessionDraft(makeDraft(id, [makeFile('f1', finalPath, 3)]))
      let result = recoverSessionDrafts()
      expect(result.recovered).assertEqual(1)
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.succeeded)
        expect(session.files[0].stage).assertEqual(SessionFileStage.completed)
      }
      let receive = getHistory()
      let matched = 0
      for (let i = 0; i < receive.length; i++) {
        if (receive[i].path === finalPath) {
          matched++
        }
      }
      expect(matched).assertEqual(1)
      expect(loadSessionDraft(id) === undefined).assertTrue()
      fs.unlinkSync(finalPath)
    })

    it('recover_partial_keeps_completed_and_cleans_temp', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-partial-' + Date.now().toString()
      let donePath = ctx.filesDir + '/' + id + '-done.txt'
      let missingPath = ctx.filesDir + '/' + id + '-missing.txt'
      writeText(donePath, 'abc')
      let tempDir = ctx.filesDir + '/.handysend-temp'
      if (!fs.accessSync(tempDir)) {
        fs.mkdirSync(tempDir, true)
      }
      let tempPath = tempDir + '/' + id + '-missing.txt'
      writeText(tempPath, 'xx')
      saveSessionDraft(makeDraft(id, [
        makeFile('f-done', donePath, 3),
        makeFile('f-missing', missingPath, 2, tempPath)
      ]))
      let result = recoverSessionDrafts()
      expect(result.recovered).assertEqual(1)
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.partiallyFailed)
      }
      let receive = getHistory()
      let matchedDone = 0
      let matchedMissing = 0
      for (let i = 0; i < receive.length; i++) {
        if (receive[i].path === donePath) {
          matchedDone++
        }
        if (receive[i].path === missingPath) {
          matchedMissing++
        }
      }
      expect(matchedDone).assertEqual(1)
      expect(matchedMissing).assertEqual(0)
      expect(fs.accessSync(tempPath)).assertFalse()
      expect(fs.accessSync(missingPath)).assertFalse()
      expect(fs.accessSync(donePath)).assertTrue()
      fs.unlinkSync(donePath)
    })

    it('recover_size_mismatch_is_partial_without_deleting_final', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-mismatch-' + Date.now().toString()
      let finalPath = ctx.filesDir + '/' + id + '.txt'
      writeText(finalPath, 'ab')
      saveSessionDraft(makeDraft(id, [makeFile('f1', finalPath, 5)]))
      recoverSessionDrafts()
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.partiallyFailed)
      }
      expect(fs.accessSync(finalPath)).assertTrue()
      let receive = getHistory()
      for (let i = 0; i < receive.length; i++) {
        expect(receive[i].path === finalPath).assertFalse()
      }
      fs.unlinkSync(finalPath)
    })

    it('recover_placeholder_draft_is_partial_without_temp_derivation', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-placeholder-' + Date.now().toString()
      saveSessionDraft(makeDraft(id, [makeFile('mta_archive', '', 100)]))
      let result = recoverSessionDrafts()
      expect(result.recovered).assertEqual(1)
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.partiallyFailed)
      }
      let receive = getHistory()
      expect(receive.length).assertEqual(0)
      expect(loadSessionDraft(id) === undefined).assertTrue()
    })

    it('recover_is_idempotent', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-idempotent-' + Date.now().toString()
      let finalPath = ctx.filesDir + '/' + id + '.txt'
      writeText(finalPath, 'abc')
      saveSessionDraft(makeDraft(id, [makeFile('f1', finalPath, 3)]))
      recoverSessionDrafts()
      recoverSessionDrafts()
      let sessions = getSessionHistory()
      let sessionCount = 0
      for (let i = 0; i < sessions.length; i++) {
        if (sessions[i].sessionId === id) {
          sessionCount++
        }
      }
      expect(sessionCount).assertEqual(1)
      let receive = getHistory()
      let pathCount = 0
      for (let i = 0; i < receive.length; i++) {
        if (receive[i].path === finalPath) {
          pathCount++
        }
      }
      expect(pathCount).assertEqual(1)
      fs.unlinkSync(finalPath)
    })
  })
}
