import 'po_token_policy.dart';
import 'po_token_provider.dart';

/// LRU cache entry key for PO tokens.
class _PoTokenCacheKey {
  final String videoId;
  final String visitorData;
  final PoTokenKind kind;

  const _PoTokenCacheKey(this.videoId, this.visitorData, this.kind);

  @override
  bool operator ==(Object other) =>
      other is _PoTokenCacheKey &&
      videoId == other.videoId &&
      visitorData == other.visitorData &&
      kind == other.kind;

  @override
  int get hashCode => Object.hash(videoId, visitorData, kind);
}

/// Wraps a [BasePoTokenProvider] with an in-memory LRU cache (yt-dlp-style).
///
/// Reduces repeated BotGuard runs for the same video/session.
class CachingPoTokenProvider extends BasePoTokenProvider {
  CachingPoTokenProvider(this._inner, {this.maxEntries = 32});

  final BasePoTokenProvider _inner;
  final int maxEntries;
  final _cache = <_PoTokenCacheKey, String>{};
  final _order = <_PoTokenCacheKey>[];

  @override
  Future<String> generatePoToken(
    String videoId,
    PoTokenContext context, {
    PoTokenKind kind = PoTokenKind.gvs,
  }) async {
    final key = _PoTokenCacheKey(videoId, context.visitorData, kind);
    final cached = _cache[key];
    if (cached != null) {
      _touch(key);
      return cached;
    }

    final token = await _inner.generatePoToken(
      videoId,
      context,
      kind: kind,
    );
    _put(key, token);
    return token;
  }

  void _touch(_PoTokenCacheKey key) {
    _order.remove(key);
    _order.add(key);
  }

  void _put(_PoTokenCacheKey key, String token) {
    if (_cache.containsKey(key)) {
      _cache[key] = token;
      _touch(key);
      return;
    }
    while (_order.length >= maxEntries) {
      final evict = _order.removeAt(0);
      _cache.remove(evict);
    }
    _cache[key] = token;
    _order.add(key);
  }

  @override
  void dispose() {
    _cache.clear();
    _order.clear();
    _inner.dispose();
  }
}
