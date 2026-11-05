// Explicit method promotion for trait impls.
//
// Newer MoonBit no longer implicitly promotes trait impl methods to regular
// methods. Keep the public method surface stable here.

// --- promoted: kept as regular methods ---

///|
pub extend ResizeMethod with Eq::{equal}

///|
pub extend ImageData with Eq::{equal}

///|
pub extend ColorType with Eq::{equal}

///|
pub extend IhdrData with Eq::{equal}

///|
pub extend ImageFormat with Eq::{equal}

///|
pub extend StreamImageInfo with Eq::{equal}

///|
pub extend ResizeMethod with Show::{output, to_string}

///|
pub extend ImageData with Show::{output, to_string}

///|
pub extend ColorType with Show::{output, to_string}

///|
pub extend IhdrData with Show::{output, to_string}

///|
pub extend ImageFormat with Show::{output, to_string}

///|
pub extend StreamImageInfo with Show::{output, to_string}

///|
pub extend DecodeError with Show::{output, to_string}

///|
pub extend EncodeError with Show::{output, to_string}

// --- deprecated: hidden from the generated interface ---

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend ResizeMethod with Eq::{not_equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend ImageData with Eq::{not_equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend ColorType with Eq::{not_equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend IhdrData with Eq::{not_equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend ImageFormat with Eq::{not_equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend StreamImageInfo with Eq::{not_equal}

///|
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend ImageData with @debug.Debug::{to_repr}

///|
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend ColorType with @debug.Debug::{to_repr}

///|
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend ImageFormat with @debug.Debug::{to_repr}
