import { createServer, stopServer, getServerStatus, pollPendingRequests, pollProgress, respondTransfer, sendFiles } from 'liblocalsend_native.so';

import { NativeServerConfig, NativeServerHandle, NativeServerStatus, NativeTargetDevice, NativeTransferRequest, NativeProgressInfo, NativeFileToSend, NativeSendResult } from '../model/NativeTypes';

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

export async function nativeRespondTransfer(sessionId: string, accept: boolean): Promise<void> {
  return await respondTransfer(sessionId, accept);
}

export async function nativeSendFiles(target: NativeTargetDevice, senderAlias: string, files: Array<NativeFileToSend>): Promise<NativeSendResult> {
  return await sendFiles(target, senderAlias, files) as NativeSendResult;
}
