import { SendSessionStatus, FileProgressStatus } from '../model/Types';

// 传输会话/文件状态的展示层映射唯一来源。
// DeviceListItem（string 状态）与 TransferSessionList（枚举状态）共用，
// 文案/颜色/错误优先顺序与整改前逐一等价。

// 将 string 状态（SendViewModel.sendSessionStatuses 存的是字符串）转为枚举；
// 非法值返回 undefined，由调用方回退。
export function sessionStatusFromString(status: string): SendSessionStatus | undefined {
  if (status === 'waiting') {
    return SendSessionStatus.waiting;
  } else if (status === 'calculatingHash') {
    return SendSessionStatus.calculatingHash;
  } else if (status === 'sending') {
    return SendSessionStatus.sending;
  } else if (status === 'finished') {
    return SendSessionStatus.finished;
  } else if (status === 'finishedWithErrors') {
    return SendSessionStatus.finishedWithErrors;
  } else if (status === 'declined') {
    return SendSessionStatus.declined;
  } else if (status === 'canceled') {
    return SendSessionStatus.canceled;
  } else if (status === 'canceledByReceiver') {
    return SendSessionStatus.canceledByReceiver;
  } else if (status === 'tooManyAttempts') {
    return SendSessionStatus.tooManyAttempts;
  } else if (status === 'viewed') {
    return SendSessionStatus.viewed;
  } else if (status === 'recipientBusy') {
    return SendSessionStatus.recipientBusy;
  } else if (status === 'timeout') {
    return SendSessionStatus.timeout;
  } else if (status === 'pinRequired') {
    return SendSessionStatus.pinRequired;
  }
  return undefined;
}

// finishedWithErrors/pinRequired 优先显示具体错误消息；无错误消息时返回 null。
export function sessionErrorMessage(status: SendSessionStatus, errorMessage: string): ResourceStr | null {
  if (status === SendSessionStatus.finishedWithErrors || status === SendSessionStatus.pinRequired) {
    if (errorMessage.length > 0) {
      return errorMessage;
    }
  }
  return null;
}

export function sessionStatusLabel(status: SendSessionStatus): ResourceStr {
  if (status === SendSessionStatus.waiting) {
    return $r('app.string.session_status_waiting');
  } else if (status === SendSessionStatus.calculatingHash) {
    return $r('app.string.session_status_checksum');
  } else if (status === SendSessionStatus.sending) {
    return $r('app.string.session_status_sending');
  } else if (status === SendSessionStatus.finished) {
    return $r('app.string.session_status_done');
  } else if (status === SendSessionStatus.finishedWithErrors) {
    return $r('app.string.session_status_error');
  } else if (status === SendSessionStatus.declined) {
    return $r('app.string.session_status_declined');
  } else if (status === SendSessionStatus.canceled || status === SendSessionStatus.canceledByReceiver) {
    return $r('app.string.session_status_canceled');
  } else if (status === SendSessionStatus.tooManyAttempts) {
    return $r('app.string.session_status_locked');
  } else if (status === SendSessionStatus.viewed) {
    return $r('app.string.session_status_viewed');
  } else if (status === SendSessionStatus.recipientBusy) {
    return $r('app.string.session_status_busy');
  } else if (status === SendSessionStatus.timeout) {
    return $r('app.string.session_status_timeout');
  } else if (status === SendSessionStatus.pinRequired) {
    return $r('app.string.session_status_pin_required');
  }
  return '';
}

export function sessionStatusColor(status: SendSessionStatus): ResourceColor {
  if (status === SendSessionStatus.sending || status === SendSessionStatus.calculatingHash) {
    return $r('app.color.accent_blue');
  } else if (status === SendSessionStatus.finished) {
    return $r('app.color.success_green');
  } else if (status === SendSessionStatus.finishedWithErrors) {
    return $r('app.color.warning_orange');
  } else if (status === SendSessionStatus.viewed) {
    return $r('app.color.success_green');
  } else if (status === SendSessionStatus.recipientBusy || status === SendSessionStatus.timeout ||
    status === SendSessionStatus.pinRequired) {
    return $r('app.color.danger_red');
  } else if (status === SendSessionStatus.declined || status === SendSessionStatus.canceled ||
    status === SendSessionStatus.canceledByReceiver || status === SendSessionStatus.tooManyAttempts) {
    return $r('app.color.danger_red');
  }
  return $r('app.color.text_secondary');
}

export function sessionStatusBgColor(status: SendSessionStatus): ResourceColor {
  if (status === SendSessionStatus.sending || status === SendSessionStatus.calculatingHash) {
    return $r('app.color.accent_blue_bg');
  } else if (status === SendSessionStatus.finished) {
    return $r('app.color.success_bg');
  } else if (status === SendSessionStatus.finishedWithErrors) {
    return $r('app.color.warning_bg');
  } else if (status === SendSessionStatus.viewed) {
    return $r('app.color.success_bg');
  } else if (status === SendSessionStatus.recipientBusy || status === SendSessionStatus.timeout ||
    status === SendSessionStatus.pinRequired) {
    return $r('app.color.danger_bg');
  } else if (status === SendSessionStatus.declined || status === SendSessionStatus.canceled ||
    status === SendSessionStatus.canceledByReceiver || status === SendSessionStatus.tooManyAttempts) {
    return $r('app.color.danger_bg');
  }
  return $r('app.color.page_background');
}

export function fileStatusLabel(status: FileProgressStatus): ResourceStr {
  if (status === FileProgressStatus.waiting) {
    return $r('app.string.file_status_waiting');
  } else if (status === FileProgressStatus.transferring) {
    return $r('app.string.file_status_transferring');
  } else if (status === FileProgressStatus.completed) {
    return $r('app.string.file_status_completed');
  } else if (status === FileProgressStatus.failed) {
    return $r('app.string.file_status_failed');
  }
  return '';
}

export function fileStatusColor(status: FileProgressStatus): ResourceColor {
  if (status === FileProgressStatus.transferring) {
    return $r('app.color.accent_blue');
  } else if (status === FileProgressStatus.completed) {
    return $r('app.color.success_green');
  } else if (status === FileProgressStatus.failed) {
    return $r('app.color.danger_red');
  }
  return $r('app.color.text_secondary');
}

export function fileStatusBgColor(status: FileProgressStatus): ResourceColor {
  if (status === FileProgressStatus.transferring) {
    return $r('app.color.accent_blue_bg');
  } else if (status === FileProgressStatus.completed) {
    return $r('app.color.success_bg');
  } else if (status === FileProgressStatus.failed) {
    return $r('app.color.danger_bg');
  }
  return $r('app.color.page_background');
}
