// AsyncBatch：受限并发的批处理执行
// 逐项 await 的串行循环在文件数较多时会把整体耗时拉长（每项都要等待一次系统调用往返），
// 选择器/媒体库来源的 URI 单次打开开销更高，串行打开数百个文件会让发送开始前等待数秒。
// 这里以固定并发度并行推进，并保持「全部完成后返回」的语义。

/** 单批并发上限：并发过高会挤占系统文件服务，过低则与串行无差别。
 *  选择器 / 媒体库来源的 URI 单次打开耗时明显高于沙箱文件，需并发抵消串行开销 */
const BATCH_CONCURRENCY_LIMIT: number = 16;

/**
 * 以受限并发对 [0, count) 依次执行 task：
 * 全部任务完成后返回；任一任务抛错时停止派发新任务，等在途任务结束后抛出首个错误。
 * 任务内部若需按序落位，请自行按下标写入预分配的数组（并发完成顺序不保证）。
 */
export async function forEachConcurrently(count: number,
  task: (index: number) => Promise<void>): Promise<void> {
  if (count <= 0) {
    return;
  }
  let next: number = 0;
  let failureMessage: string = '';
  let workers: Array<Promise<void>> = [];
  let workerCount: number = Math.min(BATCH_CONCURRENCY_LIMIT, count);

  let worker: () => Promise<void> = async (): Promise<void> => {
    for (;;) {
      if (failureMessage.length > 0) {
        return;
      }
      let index: number = next;
      next = next + 1;
      if (index >= count) {
        return;
      }
      try {
        await task(index);
      } catch (e) {
        // 只保留首个错误：后续任务不再派发
        if (failureMessage.length === 0) {
          failureMessage = String(e);
        }
        return;
      }
    }
  };

  for (let w = 0; w < workerCount; w++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  if (failureMessage.length > 0) {
    throw new Error(failureMessage);
  }
}
