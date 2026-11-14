// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'ssh.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

/// @nodoc
mixin _$SshEvent {
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(Uint8List bytes) data,
    required TResult Function(String reason) closed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(Uint8List bytes)? data,
    TResult? Function(String reason)? closed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(Uint8List bytes)? data,
    TResult Function(String reason)? closed,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(SshEvent_Data value) data,
    required TResult Function(SshEvent_Closed value) closed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(SshEvent_Data value)? data,
    TResult? Function(SshEvent_Closed value)? closed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(SshEvent_Data value)? data,
    TResult Function(SshEvent_Closed value)? closed,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SshEventCopyWith<$Res> {
  factory $SshEventCopyWith(SshEvent value, $Res Function(SshEvent) then) =
      _$SshEventCopyWithImpl<$Res, SshEvent>;
}

/// @nodoc
class _$SshEventCopyWithImpl<$Res, $Val extends SshEvent>
    implements $SshEventCopyWith<$Res> {
  _$SshEventCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of SshEvent
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc
abstract class _$$SshEvent_DataImplCopyWith<$Res> {
  factory _$$SshEvent_DataImplCopyWith(
    _$SshEvent_DataImpl value,
    $Res Function(_$SshEvent_DataImpl) then,
  ) = __$$SshEvent_DataImplCopyWithImpl<$Res>;
  @useResult
  $Res call({Uint8List bytes});
}

/// @nodoc
class __$$SshEvent_DataImplCopyWithImpl<$Res>
    extends _$SshEventCopyWithImpl<$Res, _$SshEvent_DataImpl>
    implements _$$SshEvent_DataImplCopyWith<$Res> {
  __$$SshEvent_DataImplCopyWithImpl(
    _$SshEvent_DataImpl _value,
    $Res Function(_$SshEvent_DataImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of SshEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? bytes = null}) {
    return _then(
      _$SshEvent_DataImpl(
        bytes: null == bytes
            ? _value.bytes
            : bytes // ignore: cast_nullable_to_non_nullable
                  as Uint8List,
      ),
    );
  }
}

/// @nodoc

class _$SshEvent_DataImpl extends SshEvent_Data {
  const _$SshEvent_DataImpl({required this.bytes}) : super._();

  @override
  final Uint8List bytes;

  @override
  String toString() {
    return 'SshEvent.data(bytes: $bytes)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SshEvent_DataImpl &&
            const DeepCollectionEquality().equals(other.bytes, bytes));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(bytes));

  /// Create a copy of SshEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$SshEvent_DataImplCopyWith<_$SshEvent_DataImpl> get copyWith =>
      __$$SshEvent_DataImplCopyWithImpl<_$SshEvent_DataImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(Uint8List bytes) data,
    required TResult Function(String reason) closed,
  }) {
    return data(bytes);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(Uint8List bytes)? data,
    TResult? Function(String reason)? closed,
  }) {
    return data?.call(bytes);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(Uint8List bytes)? data,
    TResult Function(String reason)? closed,
    required TResult orElse(),
  }) {
    if (data != null) {
      return data(bytes);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(SshEvent_Data value) data,
    required TResult Function(SshEvent_Closed value) closed,
  }) {
    return data(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(SshEvent_Data value)? data,
    TResult? Function(SshEvent_Closed value)? closed,
  }) {
    return data?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(SshEvent_Data value)? data,
    TResult Function(SshEvent_Closed value)? closed,
    required TResult orElse(),
  }) {
    if (data != null) {
      return data(this);
    }
    return orElse();
  }
}

abstract class SshEvent_Data extends SshEvent {
  const factory SshEvent_Data({required Uint8List bytes}) = _$SshEvent_DataImpl;
  const SshEvent_Data._() : super._();

  Uint8List get bytes;

  /// Create a copy of SshEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$SshEvent_DataImplCopyWith<_$SshEvent_DataImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$SshEvent_ClosedImplCopyWith<$Res> {
  factory _$$SshEvent_ClosedImplCopyWith(
    _$SshEvent_ClosedImpl value,
    $Res Function(_$SshEvent_ClosedImpl) then,
  ) = __$$SshEvent_ClosedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({String reason});
}

/// @nodoc
class __$$SshEvent_ClosedImplCopyWithImpl<$Res>
    extends _$SshEventCopyWithImpl<$Res, _$SshEvent_ClosedImpl>
    implements _$$SshEvent_ClosedImplCopyWith<$Res> {
  __$$SshEvent_ClosedImplCopyWithImpl(
    _$SshEvent_ClosedImpl _value,
    $Res Function(_$SshEvent_ClosedImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of SshEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? reason = null}) {
    return _then(
      _$SshEvent_ClosedImpl(
        reason: null == reason
            ? _value.reason
            : reason // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc

class _$SshEvent_ClosedImpl extends SshEvent_Closed {
  const _$SshEvent_ClosedImpl({required this.reason}) : super._();

  @override
  final String reason;

  @override
  String toString() {
    return 'SshEvent.closed(reason: $reason)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SshEvent_ClosedImpl &&
            (identical(other.reason, reason) || other.reason == reason));
  }

  @override
  int get hashCode => Object.hash(runtimeType, reason);

  /// Create a copy of SshEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$SshEvent_ClosedImplCopyWith<_$SshEvent_ClosedImpl> get copyWith =>
      __$$SshEvent_ClosedImplCopyWithImpl<_$SshEvent_ClosedImpl>(
        this,
        _$identity,
      );

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(Uint8List bytes) data,
    required TResult Function(String reason) closed,
  }) {
    return closed(reason);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(Uint8List bytes)? data,
    TResult? Function(String reason)? closed,
  }) {
    return closed?.call(reason);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(Uint8List bytes)? data,
    TResult Function(String reason)? closed,
    required TResult orElse(),
  }) {
    if (closed != null) {
      return closed(reason);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(SshEvent_Data value) data,
    required TResult Function(SshEvent_Closed value) closed,
  }) {
    return closed(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(SshEvent_Data value)? data,
    TResult? Function(SshEvent_Closed value)? closed,
  }) {
    return closed?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(SshEvent_Data value)? data,
    TResult Function(SshEvent_Closed value)? closed,
    required TResult orElse(),
  }) {
    if (closed != null) {
      return closed(this);
    }
    return orElse();
  }
}

abstract class SshEvent_Closed extends SshEvent {
  const factory SshEvent_Closed({required String reason}) =
      _$SshEvent_ClosedImpl;
  const SshEvent_Closed._() : super._();

  String get reason;

  /// Create a copy of SshEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$SshEvent_ClosedImplCopyWith<_$SshEvent_ClosedImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
