/// Phase 1 のこのターゲットには実装が無い。それでもこの型を置いているのは、
/// ソースが空のターゲットを product が参照すると SwiftPM が
/// `target 'Adapters' ... is empty` で失敗するため。実装が入ったら削除する。
enum AdaptersPlaceholder {}
