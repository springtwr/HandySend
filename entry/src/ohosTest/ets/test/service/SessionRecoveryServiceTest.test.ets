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
  removeSessionDraft,
  saveSessionDraft,
  sessionDraftDir
} from '../../../../main/ets/service/transfer/SessionDraftStore'
import {
  createSession,
  finish,
  markFileStage,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
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
      let tempDir = ctx.filesDir + '/.handysend-temp/localsend'
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
        expect(session.outcome).assertEqual(SessionHistoryOutcome.failed)
      }
      expect(fs.accessSync(finalPath)).assertTrue()
      let receive = getHistory()
      for (let i = 0; i < receive.length; i++) {
        expect(receive[i].path === finalPath).assertFalse()
      }
      fs.unlinkSync(finalPath)
    })

    it('recover_placeholder_draft_is_failed_without_temp_derivation', 0, () => {
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
        expect(session.outcome).assertEqual(SessionHistoryOutcome.failed)
      }
      let receive = getHistory()
      expect(receive.length).assertEqual(0)
      expect(loadSessionDraft(id) === undefined).assertTrue()
    })

    it('recover_pending_draft_is_cancelled_not_partial', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-pending-' + Date.now().toString()
      let draft = makeDraft(id, [
        makeFile('f-waiting-1', '', 10),
        makeFile('f-waiting-2', '', 20)
      ])
      draft.stage = SessionStage.awaitingConfirmation
      saveSessionDraft(draft)
      let result = recoverSessionDrafts()
      expect(result.recovered).assertEqual(1)
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.cancelled)
        expect(session.errorCode).assertEqual('app_killed_before_start')
        expect(session.files[0].stage).assertEqual(SessionFileStage.cancelled)
        expect(session.files[1].stage).assertEqual(SessionFileStage.cancelled)
      }
      let receive = getHistory()
      expect(receive.length).assertEqual(0)
      expect(loadSessionDraft(id) === undefined).assertTrue()
    })

    it('recover_outbound_draft_writes_task_only', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-outbound-' + Date.now().toString()
      let completed = makeFile('f-sent', '/tmp/sent-source.txt', 10)
      completed.stage = SessionFileStage.completed
      completed.bytesSent = 10
      let draft = makeDraft(id, [completed, makeFile('f-pending', '', 20)])
      draft.dataFlow = SessionDataFlow.outbound
      saveSessionDraft(draft)
      recoverSessionDrafts()
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.partiallyFailed)
        expect(session.errorCode).assertEqual('app_killed')
        expect(session.files[0].stage).assertEqual(SessionFileStage.completed)
        expect(session.files[0].path).assertEqual('/tmp/sent-source.txt')
        expect(session.files[1].stage).assertEqual(SessionFileStage.failed)
      }
      let receive = getHistory()
      expect(receive.length).assertEqual(0)
      expect(loadSessionDraft(id) === undefined).assertTrue()
    })

    it('recover_outbound_pending_draft_is_cancelled', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-outbound-pending-' + Date.now().toString()
      let draft = makeDraft(id, [makeFile('f-waiting', '', 10)])
      draft.dataFlow = SessionDataFlow.outbound
      draft.stage = SessionStage.awaitingConfirmation
      saveSessionDraft(draft)
      recoverSessionDrafts()
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.cancelled)
        expect(session.errorCode).assertEqual('app_killed_before_start')
        expect(session.files[0].stage).assertEqual(SessionFileStage.cancelled)
      }
      let receive = getHistory()
      expect(receive.length).assertEqual(0)
      expect(loadSessionDraft(id) === undefined).assertTrue()
    })

    it('recover_terminal_outbound_draft_keeps_outcome', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-outbound-terminal-' + Date.now().toString()
      let file = makeFile('f-sent', '', 10)
      file.stage = SessionFileStage.completed
      file.bytesSent = 10
      let draft = makeDraft(id, [file])
      draft.dataFlow = SessionDataFlow.outbound
      draft.stage = SessionStage.succeeded
      saveSessionDraft(draft)
      recoverSessionDrafts()
      let session = findSession(id)
      expect(session !== undefined).assertTrue()
      if (session !== undefined) {
        expect(session.outcome).assertEqual(SessionHistoryOutcome.succeeded)
      }
      expect(getHistory().length).assertEqual(0)
      expect(loadSessionDraft(id) === undefined).assertTrue()
    })

    it('outbound_session_creation_writes_pending_draft', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearDrafts()
      let session = createSession({
        protocolKey: 'test-send',
        protocolSessionId: '',
        dataFlow: SessionDataFlow.outbound,
        initiatedBy: SessionInitiator.local,
        peer: {
          displayName: 'peer',
          badges: []
        },
        files: [{
          fileId: 'f-send-1',
          fileName: 'a.txt',
          fileType: 'text/plain',
          totalBytes: 3,
          path: '/tmp/source-a.txt'
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
      let draft = loadSessionDraft(session.id)
      expect(draft !== undefined).assertTrue()
      if (draft !== undefined) {
        expect(draft.dataFlow).assertEqual(SessionDataFlow.outbound)
        expect(draft.files[0].finalPath).assertEqual('/tmp/source-a.txt')
      }
      removeSessionDraft(session.id)
      resetRegistry()
    })

    it('markFileStage_persists_outbound_draft_completion', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearDrafts()
      let session = createSession({
        protocolKey: 'test-mark-stage',
        protocolSessionId: '',
        dataFlow: SessionDataFlow.outbound,
        initiatedBy: SessionInitiator.local,
        peer: {
          displayName: 'peer',
          badges: []
        },
        files: [{
          fileId: 'f-stage',
          fileName: 'a.txt',
          fileType: 'text/plain',
          totalBytes: 3,
          path: '/tmp/a.txt'
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
      // 网页下载的完成事件可能只经 markFileStage 进入，不再经过字节进度
      markFileStage(session.id, 'f-stage', SessionFileStage.completed)
      let draft = loadSessionDraft(session.id)
      expect(draft !== undefined).assertTrue()
      if (draft !== undefined) {
        expect(draft.files[0].stage).assertEqual(SessionFileStage.completed)
      }
      removeSessionDraft(session.id)
      resetRegistry()
    })

    it('recovery_skips_active_session_draft', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearDrafts()
      clearSessionHistory()
      let session = createSession({
        protocolKey: 'test-send-active',
        protocolSessionId: '',
        dataFlow: SessionDataFlow.outbound,
        initiatedBy: SessionInitiator.local,
        peer: {
          displayName: 'peer',
          badges: []
        },
        files: [{
          fileId: 'f-active',
          fileName: 'a.txt',
          fileType: 'text/plain',
          totalBytes: 3,
          path: '/tmp/active-a.txt'
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
      recoverSessionDrafts()
      // 活跃会话不能被恢复成历史失败任务，草稿保留给后续终端或下次冷启动处理。
      expect(loadSessionDraft(session.id) !== undefined).assertTrue()
      let sessions = getSessionHistory()
      for (let i = 0; i < sessions.length; i++) {
        expect(sessions[i].sessionId === session.id).assertFalse()
      }
      removeSessionDraft(session.id)
      resetRegistry()
    })

    it('recover_sweeps_all_protocol_temp_dirs', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let id = 'recover-mta-temp-' + Date.now().toString()
      let targetDir = ctx.filesDir + '/' + id + '-target'
      let mtaTemp = targetDir + '/.handysend-temp/mta'
      let localTemp = targetDir + '/.handysend-temp/localsend'
      let legacyTemp = targetDir + '/.handysend-temp/local-send'
      fs.mkdirSync(mtaTemp, true)
      fs.mkdirSync(localTemp, true)
      fs.mkdirSync(legacyTemp, true)
      writeText(mtaTemp + '/partial.bin', 'xx')
      writeText(localTemp + '/stale.bin', 'stale')
      writeText(legacyTemp + '/old.bin', 'old')
      writeText(targetDir + '/user.txt', 'mine')
      let draft = makeDraft(id, [makeFile('mta_archive', '', 100)])
      draft.protocolKey = 'mta-receive'
      draft.targetDir = targetDir
      saveSessionDraft(draft)

      recoverSessionDrafts()

      expect(fs.accessSync(mtaTemp + '/partial.bin')).assertFalse()
      expect(fs.accessSync(localTemp + '/stale.bin')).assertFalse()
      expect(fs.accessSync(legacyTemp + '/old.bin')).assertFalse()
      expect(fs.accessSync(targetDir + '/.handysend-temp')).assertFalse()
      expect(fs.accessSync(targetDir + '/user.txt')).assertTrue()
      expect(loadSessionDraft(id) === undefined).assertTrue()
      fs.unlinkSync(targetDir + '/user.txt')
      fs.rmdirSync(targetDir)
    })

    it('recovery_keeps_active_session_temp', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearDrafts()
      clearSessionHistory()
      let id = 'recover-active-temp-' + Date.now().toString()
      let targetDir = ctx.filesDir + '/' + id + '-target'
      let tempDir = targetDir + '/.handysend-temp/localsend'
      fs.mkdirSync(tempDir, true)
      let tempPath = tempDir + '/active.bin'
      writeText(tempPath, 'inflight')
      let session = createSession({
        protocolKey: 'test-recv-active',
        protocolSessionId: '',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: {
          displayName: 'peer',
          badges: []
        },
        files: [{
          fileId: 'f-active',
          fileName: 'active.bin',
          fileType: '',
          totalBytes: 8,
          path: targetDir + '/active.bin'
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
      let draft = makeDraft(session.id,
        [makeFile('f-active', targetDir + '/active.bin', 8, tempPath)])
      saveSessionDraft(draft)

      recoverSessionDrafts()

      // 活跃会话正在写入的临时文件不能被清扫，草稿也保留。
      expect(fs.accessSync(tempPath)).assertTrue()
      expect(loadSessionDraft(session.id) !== undefined).assertTrue()
      removeSessionDraft(session.id)
      fs.unlinkSync(tempPath)
      fs.rmdirSync(tempDir)
      fs.rmdirSync(targetDir + '/.handysend-temp')
      fs.rmdirSync(targetDir)
      resetRegistry()
    })

    it('recovery_does_not_overwrite_existing_history', 0, () => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        return
      }
      clearAll()
      clearSessionHistory()
      clearDrafts()
      let session = createSession({
        protocolKey: 'test-recovery-existing',
        protocolSessionId: 'recovery-existing',
        dataFlow: SessionDataFlow.inbound,
        initiatedBy: SessionInitiator.remote,
        peer: {
          displayName: 'peer',
          badges: []
        },
        files: [{
          fileId: 'f1',
          fileName: 'a.txt',
          fileType: 'text/plain',
          totalBytes: 10
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
      finish(session.id, SessionStage.failed, '存储空间不足', 'storage_full')
      // 模拟协议漏删的残留草稿：若恢复直接归档，会把真实失败原因覆盖为 app_killed
      saveSessionDraft(makeDraft(session.id, [makeFile('f1', '', 10)]))
      recoverSessionDrafts()
      let found = findSession(session.id)
      expect(found !== undefined).assertTrue()
      if (found !== undefined) {
        expect(found.errorCode).assertEqual('storage_full')
        expect(found.errorMessage).assertEqual('存储空间不足')
      }
      expect(loadSessionDraft(session.id) === undefined).assertTrue()
      removeSessionDraft(session.id)
      resetRegistry()
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
