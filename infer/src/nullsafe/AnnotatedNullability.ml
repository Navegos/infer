(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

(** Representation of a (non local) type in Java program, with added information about its
    nullability, according to the source code. Nullability information might come either from
    explicit annotations, or from other sources, including conventions about defaults. Note that
    nullsafe omits Nullability information in types used for local variable declarations: this
    information is inferred according to flow-sensitive inferrence rule. *)

(** See {!Nullability.t} for explanation *)
type t =
  | Nullable of nullable_origin
  | ThirdPartyNonnull
  | UncheckedNonnull of unchecked_nonnull_origin
  | LocallyCheckedNonnull
  | StrictNonnull of strict_nonnull_origin
[@@deriving compare]

and nullable_origin =
  | AnnotatedNullable
  | AnnotatedPropagatesNullable
  | HasPropagatesNullableInParam
  | ModelledNullable
[@@deriving compare]

and unchecked_nonnull_origin = AnnotatedNonnull | ImplicitlyNonnull

and strict_nonnull_origin =
  | ExplicitNonnullThirdParty
  | ModelledNonnull
  | StrictMode
  | PrimitiveType
  | EnumValue
[@@deriving compare]

let get_nullability = function
  | Nullable _ ->
      Nullability.Nullable
  | ThirdPartyNonnull ->
      Nullability.ThirdPartyNonnull
  | UncheckedNonnull _ ->
      Nullability.UncheckedNonnull
  | LocallyCheckedNonnull ->
      Nullability.LocallyCheckedNonnull
  | StrictNonnull _ ->
      Nullability.StrictNonnull


let pp fmt t =
  let string_of_nullable_origin nullable_origin =
    match nullable_origin with
    | AnnotatedNullable ->
        "@"
    | AnnotatedPropagatesNullable ->
        "propagates"
    | HasPropagatesNullableInParam ->
        "<-propagates"
    | ModelledNullable ->
        "model"
  in
  let string_of_declared_nonnull_origin origin =
    match origin with AnnotatedNonnull -> "@" | ImplicitlyNonnull -> "implicit"
  in
  let string_of_nonnull_origin nonnull_origin =
    match nonnull_origin with
    | ExplicitNonnullThirdParty ->
        "explicit3p"
    | ModelledNonnull ->
        "model"
    | StrictMode ->
        "strict"
    | PrimitiveType ->
        "primitive"
    | EnumValue ->
        "enum"
  in
  match t with
  | Nullable origin ->
      F.fprintf fmt "Nullable[%s]" (string_of_nullable_origin origin)
  | ThirdPartyNonnull ->
      F.fprintf fmt "ThirdPartyNonnull"
  | UncheckedNonnull origin ->
      F.fprintf fmt "UncheckedNonnull[%s]" (string_of_declared_nonnull_origin origin)
  | LocallyCheckedNonnull ->
      F.fprintf fmt "LocallyCheckedNonnull"
  | StrictNonnull origin ->
      F.fprintf fmt "StrictNonnull[%s]" (string_of_nonnull_origin origin)


let of_type_and_annotation ~is_trusted_callee ~nullsafe_mode ~is_third_party typ annotations =
  if not (PatternMatch.type_is_class typ) then StrictNonnull PrimitiveType
  else if Annotations.ia_is_nullable annotations then
    (* Explicitly nullable always means Nullable *)
    let nullable_origin =
      if Annotations.ia_is_propagates_nullable annotations then AnnotatedPropagatesNullable
      else AnnotatedNullable
    in
    Nullable nullable_origin
  else
    (* Lack of nullable annotation means non-nullish case, lets specify which exactly. *)
    match nullsafe_mode with
    | NullsafeMode.Strict ->
        (* In strict mode, not annotated with nullable means non-nullable *)
        StrictNonnull StrictMode
    | NullsafeMode.Local _ ->
        (* In local mode, not annotated with nullable means non-nullable *)
        LocallyCheckedNonnull
    | NullsafeMode.Default ->
        (* In default mode, agreements for "not [@Nullable]" depend on where code comes from *)
        if is_third_party then
          if Annotations.ia_is_nonnull annotations then
            (* Third party method explicitly marked as [@Nonnull].
               This is considered strict - see documentation to [ExplicitNonnullThirdParty]
               **)
            StrictNonnull ExplicitNonnullThirdParty
          else
            (* Third party might not obey "not annotated hence not nullable" convention.
               Hence by default we treat is with low level of trust.
            *)
            ThirdPartyNonnull
        else
          (* For non third party code, the agreement is "not annotated with [@Nullable] hence not null" *)
          let preliminary_nullability =
            if Annotations.ia_is_nonnull annotations then UncheckedNonnull AnnotatedNonnull
            else UncheckedNonnull ImplicitlyNonnull
          in
          if is_trusted_callee then LocallyCheckedNonnull else preliminary_nullability
