// 进程内 WS 订阅广播：push 成功后通知各端拉取增量（订阅端积压即丢弃，客户端靠 pull 对账）。
// 评审 BUG-1（2026-11-27）：订阅/广播带 vault 维度——通知面与数据面同受租户边界约束，
// 他 vault 的 push 不再唤醒本 vault 的在线客户端（跨租户元数据泄露 + 无谓耗电）。

export class Hub {
  private subs = new Map<string, Set<(rev: number) => void>>();

  /** 订阅指定 vault 的变更通知；返回取消函数。 */
  subscribe(vaultId: Buffer, fn: (rev: number) => void): () => void {
    const key = vaultId.toString("hex");
    let set = this.subs.get(key);
    if (!set) {
      set = new Set();
      this.subs.set(key, set);
    }
    set.add(fn);
    return () => {
      set.delete(fn);
      if (set.size === 0) this.subs.delete(key);
    };
  }

  /** 向订阅了该 vault 的客户端广播变更通知（其他 vault 不受影响）。 */
  broadcast(vaultId: Buffer, rev: number): void {
    const key = vaultId.toString("hex");
    for (const fn of this.subs.get(key) ?? []) {
      try {
        fn(rev);
      } catch {
        // 单个订阅端失败不影响其他端
      }
    }
  }

  count(): number {
    let n = 0;
    for (const s of this.subs.values()) n += s.size;
    return n;
  }
}
