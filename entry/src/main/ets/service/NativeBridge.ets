import { createServer, stopServer, getServerStatus, pollPendingRequests, pollProgress, pollSendProgress, respondTransfer, sendFiles, createShareLink, stopShareServer, pollShareProgress, getRecvDiag, cancelTransfer, cancelLocalSession, getCurrentSendSessionId, pollDebugLog } from 'liblocalsend_native.so';

import { NativeServerConfig, NativeServerHandle, NativeServerStatus, NativeTargetDevice, NativeTransferRequest, NativeProgressInfo, NativeFileToSend, NativeSendResult, NativeShareLinkInfo, NativeRecvDiag, NativeCancelTarget
} from '../model/NativeTypes';

export async function nativeCreateServer(config: NativeServerConfig): Promise<NativeServerHandle> {
  return await createServer(config) as NativeServerHandle;
}

export async function nativeStopServer(): Promise<void> {
  return await stopServer();
}

export function nativeGetServerStatus(): NativeServerStatus {
  return getServerStatus() as NativeServerStatus;
}

export function nativePollPendingRequests(): Array<NativeTransferRequest> {
  return pollPendingRequests() as Array<NativeTransferRequest>;
}

export function nativePollProgress(): Array<NativeProgressInfo> {
  return pollProgress() as Array<NativeProgressInfo>;
}

export function nativePollSendProgress(): Array<NativeProgressInfo> {
  return pollSendProgress() as Array<NativeProgressInfo>;
}

export async function nativeCreateShareLink(files: Array<NativeFileToSend>, alias: string): Promise<NativeShareLinkInfo> {
  return await createShareLink(files, alias) as NativeShareLinkInfo;
}

export async function nativeStopShareServer(): Promise<void> {
  return await stopShareServer();
}

export function nativePollShareProgress(): Array<NativeProgressInfo> {
  return pollShareProgress() as Array<NativeProgressInfo>;
}

export async function nativeRespondTransfer(sessionId: string, accept: boolean, acceptedFileIds: Array<string> = []): Promise<void> {
  return await respondTransfer(sessionId, accept, acceptedFileIds);
}

export async function nativeSendFiles(target: NativeTargetDevice, senderAlias: string, files: Array<NativeFileToSend>): Promise<NativeSendResult> {
  return await sendFiles(target, senderAlias, files) as NativeSendResult;
}

export function nativeGetRecvDiag(): NativeRecvDiag {
  return getRecvDiag() as NativeRecvDiag;
}

export async function nativeCancelTransfer(target: NativeCancelTarget, sessionId: string): Promise<void> {
  return await cancelTransfer(target, sessionId);
}

export async function nativeCancelLocalSession(sessionId: string): Promise<void> {
  return await cancelLocalSession(sessionId);
}

export function nativeGetCurrentSendSessionId(): string {
  return getCurrentSendSessionId();
}

export function nativePollDebugLog(): Array<string> {
  return pollDebugLog();
}

// ── Placeholder NAPI functions for feature alignment ──
// These functions may not exist yet in the Rust NAPI library.
// They are declared here for future integration; actual calls are
// guarded at the AppService level with try/catch and fallback logic.

// TODO: Uncomment when Rust NAPI library supports setReceivePin
// export async function nativeSetReceivePin(pin: string): Promise<void> {
//   return await setReceivePin(pin);
// }

// TODO: Uncomment when Rust NAPI library supports setWebUpload
// export async function nativeSetWebUpload(config: WebUploadConfig): Promise<void> {
//   return await setWebUpload(config);
// }

// TODO: Uncomment when Rust NAPI library supports setWebPin
// export async function nativeSetWebPin(pin: string): Promise<void> {
//   return await setWebPin(pin);
// }

// TODO: Uncomment when Rust NAPI library supports calculateFileHash
// export async function nativeCalculateFileHash(filePath: string): Promise<FileHashResult> {
//   return await calculateFileHash(filePath) as FileHashResult;
// }

// TODO: Uncomment when Rust NAPI library supports setVerifyChecksums
// export async function nativeSetVerifyChecksums(enabled: boolean): Promise<void> {
//   return await setVerifyChecksums(enabled);
// }

// TODO: Uncomment when Rust NAPI library supports setCreateChecksums
// export async function nativeSetCreateChecksums(enabled: boolean): Promise<void> {
//   return await setCreateChecksums(enabled);
// }
