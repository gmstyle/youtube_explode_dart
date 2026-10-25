// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'thumbnail_set.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ThumbnailSet {

/// Video id.
 String get videoId;
/// Create a copy of ThumbnailSet
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ThumbnailSetCopyWith<ThumbnailSet> get copyWith => _$ThumbnailSetCopyWithImpl<ThumbnailSet>(this as ThumbnailSet, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ThumbnailSet;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ThumbnailSet&&(identical(other.videoId, _this.videoId) || other.videoId == _this.videoId));
}


@override
int get hashCode {
  final _this = this as ThumbnailSet;
  return Object.hash(runtimeType,_this.videoId);
}

@override
String toString() {
  final _this = this as ThumbnailSet;
  return 'ThumbnailSet(videoId: ${_this.videoId})';
}


}

/// @nodoc
abstract mixin class $ThumbnailSetCopyWith<$Res>  {
  factory $ThumbnailSetCopyWith(ThumbnailSet value, $Res Function(ThumbnailSet) _then) = _$ThumbnailSetCopyWithImpl;
@useResult
$Res call({
 String videoId
});




}
/// @nodoc
class _$ThumbnailSetCopyWithImpl<$Res>
    implements $ThumbnailSetCopyWith<$Res> {
  _$ThumbnailSetCopyWithImpl(this._self, this._then);

  final ThumbnailSet _self;
  final $Res Function(ThumbnailSet) _then;

/// Create a copy of ThumbnailSet
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? videoId = null,}) {
  return _then(ThumbnailSet(
null == videoId ? _self.videoId : videoId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}



/// @nodoc


class _ThumbnailSet extends ThumbnailSet {
  const _ThumbnailSet(this.videoId): super._();
  

/// Video id.
@override final  String videoId;

/// Create a copy of ThumbnailSet
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ThumbnailSetCopyWith<_ThumbnailSet> get copyWith => __$ThumbnailSetCopyWithImpl<_ThumbnailSet>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ThumbnailSet&&(identical(other.videoId, videoId) || other.videoId == videoId));
}


@override
int get hashCode {
    return Object.hash(runtimeType,videoId);
}

@override
String toString() {
    return 'ThumbnailSet(videoId: $videoId)';
}


}

/// @nodoc
abstract mixin class _$ThumbnailSetCopyWith<$Res> implements $ThumbnailSetCopyWith<$Res> {
  factory _$ThumbnailSetCopyWith(_ThumbnailSet value, $Res Function(_ThumbnailSet) _then) = __$ThumbnailSetCopyWithImpl;
@override @useResult
$Res call({
 String videoId
});




}
/// @nodoc
class __$ThumbnailSetCopyWithImpl<$Res>
    implements _$ThumbnailSetCopyWith<$Res> {
  __$ThumbnailSetCopyWithImpl(this._self, this._then);

  final _ThumbnailSet _self;
  final $Res Function(_ThumbnailSet) _then;

/// Create a copy of ThumbnailSet
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? videoId = null,}) {
  return _then(_ThumbnailSet(
null == videoId ? _self.videoId : videoId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
