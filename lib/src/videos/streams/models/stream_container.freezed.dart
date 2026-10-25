// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'stream_container.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$StreamContainer {

/// Container name.
/// Can be used as file extension
 String get name;

  /// Serializes this StreamContainer to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as StreamContainer;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StreamContainer&&(identical(other.name, _this.name) || other.name == _this.name));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as StreamContainer;
  return Object.hash(runtimeType,_this.name);
}



}





/// @nodoc
@JsonSerializable()

class _StreamContainer extends StreamContainer {
  const _StreamContainer(this.name): super._();
  factory _StreamContainer.fromJson(Map<String, dynamic> json) => _$StreamContainerFromJson(json);

/// Container name.
/// Can be used as file extension
@override final  String name;


@override
Map<String, dynamic> toJson() {
  return _$StreamContainerToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _StreamContainer&&(identical(other.name, name) || other.name == name));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,name);
}



}




// dart format on
