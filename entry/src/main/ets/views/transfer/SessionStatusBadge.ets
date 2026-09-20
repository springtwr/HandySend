/**
 * SessionStatusBadge.ets — 统一会话状态徽标与配色
 *
 * 协议无关的状态标签唯一来源：中心列表与详情页共用文案/颜色映射。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionFileStage, SessionStage, isTerminalStage } from '../../model/transfer/TransferSession';

/** 逐文件阶段 → 文案（详情页文件卡状态徽标）。 */
export function sessionFileStageLabel(stage: SessionFileStage): ResourceStr {
  if (stage === SessionFileStage.waiting) {
    return $r('app.string.file_status_waiting');
  }
  if (stage === SessionFileStage.transferring) {
    return $r('app.string.file_status_transferring');
  }
  if (stage === SessionFileStage.completed) {
    return $r('app.string.file_status_completed');
  }
  if (stage === SessionFileStage.failed) {
    return $r('app.string.file_status_failed');
  }
  return '';
}

/** 逐文件阶段 → 前景色。 */
export function sessionFileStageColor(stage: SessionFileStage): ResourceColor {
  if (stage === SessionFileStage.transferring) {
    return $r('app.color.accent_blue');
  }
  if (stage === SessionFileStage.completed) {
    return $r('app.color.success_green');
  }
  if (stage === SessionFileStage.failed) {
    return $r('app.color.danger_red');
  }
  return $r('app.color.text_secondary');
}

/** 逐文件阶段 → 背景色。 */
export function sessionFileStageBgColor(stage: SessionFileStage): ResourceColor {
  if (stage === SessionFileStage.transferring) {
    return $r('app.color.accent_blue_bg');
  }
  if (stage === SessionFileStage.completed) {
    return $r('app.color.success_bg');
  }
  if (stage === SessionFileStage.failed) {
    return $r('app.color.danger_bg');
  }
  return $r('app.color.page_background');
}

/** 统一状态 → 文案。 */
export function sessionStageLabel(stage: SessionStage): ResourceStr {
  if (stage === SessionStage.awaitingConfirmation) {
    return $r('app.string.session_stage_awaiting');
  }
  if (stage === SessionStage.active) {
    return $r('app.string.session_stage_active');
  }
  if (stage === SessionStage.succeeded) {
    return $r('app.string.session_stage_succeeded');
  }
  if (stage === SessionStage.partiallyFailed) {
    return $r('app.string.session_stage_partial');
  }
  if (stage === SessionStage.failed) {
    return $r('app.string.session_stage_failed');
  }
  if (stage === SessionStage.cancelled) {
    return $r('app.string.session_stage_cancelled');
  }
  if (stage === SessionStage.declined) {
    return $r('app.string.session_stage_declined');
  }
  return '';
}

/** 统一状态 → 前景色。 */
export function sessionStageColor(stage: SessionStage): ResourceColor {
  if (stage === SessionStage.active) {
    return $r('app.color.accent_blue');
  }
  if (stage === SessionStage.awaitingConfirmation) {
    return $r('app.color.warning_orange');
  }
  if (stage === SessionStage.succeeded) {
    return $r('app.color.success_green');
  }
  if (stage === SessionStage.partiallyFailed) {
    return $r('app.color.warning_orange');
  }
  if (stage === SessionStage.failed) {
    return $r('app.color.danger_red');
  }
  return $r('app.color.text_secondary');
}

/** 统一状态 → 背景色。 */
export function sessionStageBgColor(stage: SessionStage): ResourceColor {
  if (stage === SessionStage.active) {
    return $r('app.color.accent_blue_bg');
  }
  if (stage === SessionStage.awaitingConfirmation) {
    return $r('app.color.warning_bg');
  }
  if (stage === SessionStage.succeeded) {
    return $r('app.color.success_bg');
  }
  if (stage === SessionStage.partiallyFailed) {
    return $r('app.color.warning_bg');
  }
  if (stage === SessionStage.failed) {
    return $r('app.color.danger_bg');
  }
  return $r('app.color.page_background');
}

/**
 * 徽标展示文案：
 * - 终态恒由统一状态映射决定（忽略可能残留的进行中阶段文案，防止终态展示为进行中）；
 * - 非终态保持离散阶段文案优先（无字节进度协议），空则回退统一状态映射。
 */
export function sessionBadgeText(stage: SessionStage, stageText: ResourceStr): ResourceStr {
  if (isTerminalStage(stage)) {
    return sessionStageLabel(stage);
  }
  if (typeof stageText === 'string') {
    return stageText.length > 0 ? stageText : sessionStageLabel(stage);
  }
  return stageText;
}

@ComponentV2
export struct SessionStatusBadge {
  @Require @Param stage: SessionStage
  // 离散阶段文案（无字节进度协议）；非终态且非空时优先展示
  @Param stageText: ResourceStr = ''

  /** 展示文案：终态取统一状态文案，非终态离散阶段文案优先。 */
  private stageTextShown(): ResourceStr {
    return sessionBadgeText(this.stage, this.stageText);
  }

  build() {
    Text(this.stageTextShown())
      .fontSize(DesignTokens.font.bodyS)
      .fontColor(sessionStageColor(this.stage))
      .backgroundColor(sessionStageBgColor(this.stage))
      .padding({
        left: DesignTokens.space.tiny,
        right: DesignTokens.space.tiny,
        top: DesignTokens.space.mini,
        bottom: DesignTokens.space.mini
      })
      .borderRadius(DesignTokens.radius.sm)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .accessibilityGroup(true)
  }
}
