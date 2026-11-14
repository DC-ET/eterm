// 进程内 WS 订阅广播：push 成功后通知各端拉取增量（订阅端积压即丢弃，客户端靠 pull 对账）。

export class Hub {
  private subs = new Set<(rev: number) => void>();

  subscribe(fn: (rev: number) => void): () => void {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }

  broadcast(rev: number): void {
    for (const fn of this.subs) {
      try {
        fn(rev);
      } catch {
        // 单个订阅端失败不影响其他端
      }
    }
  }

  count(): number {
    return this.subs.size;
  }
}
