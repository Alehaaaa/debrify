import 'package:flutter/foundation.dart';
import '../models/torbox_user.dart';
import '../services/storage_service.dart';
import '../services/torbox_service.dart';
import '../models/profiles/profile_policy.dart';
import 'profiles/profile_async_authorization.dart';
import 'profiles/connection_resource_service.dart';

class TorboxAccountService {
  static TorboxUser? _currentUser;
  static bool _isValidating = false;
  static int _validationToken = 0;
  static Future<bool>? _pendingValidation;
  static String? _pendingApiKey;
  static bool _pendingPersists = false;
  static String? _lastValidationError;

  /// Dependency seam for deterministic account-validation tests only.
  @visibleForTesting
  static Future<TorboxUser> Function(String apiKey)? debugUserInfoFetcher;

  /// Notifier for reactive UI updates when user state changes
  static final ValueNotifier<TorboxUser?> userNotifier = ValueNotifier(null);

  static TorboxUser? get currentUser => _currentUser;

  static bool get isValidating => _isValidating;

  /// A provider timeout is not an invalid key. Keep the last successful user
  /// snapshot and expose the actual (sanitized) failure to Settings.
  static String? get lastValidationError => _lastValidationError;

  @visibleForTesting
  static String validationErrorFor(Object error) {
    if (error is TorboxAuthorizationException) {
      return 'Torbox rejected this API key or account permission (${error.statusCode}). Check your account and API key.';
    }
    if (error is TorboxConnectionException) {
      switch (error.kind) {
        case TorboxConnectionFailureKind.timeout:
          return 'Torbox did not respond in time. Your API key has not been rejected; retry when the service responds.';
        case TorboxConnectionFailureKind.rateLimited:
          return 'Torbox is rate-limiting requests. Try again shortly; the API key was not rejected.';
        case TorboxConnectionFailureKind.server:
          return 'Torbox reported a temporary server error. Please retry later.';
        case TorboxConnectionFailureKind.network:
          return 'Cannot reach Torbox right now. Check connectivity and retry.';
      }
    }
    return 'Could not verify the Torbox connection. Please try again; this does not prove the API key is invalid.';
  }

  // Internal setter that also notifies listeners
  static void _setCurrentUser(TorboxUser? user) {
    _currentUser = user;
    userNotifier.value = user;
  }

  static Future<bool> validateAndGetUserInfo(
    String apiKey, {
    bool persist = true,
  }) {
    // Several screens can refresh the same account during startup. Previously
    // the second caller immediately received `false` ("invalid credentials")
    // while the first network request was still running. Reuse the exact same
    // validation, except when it would skip a caller's explicit save action.
    final pending = _pendingValidation;
    if (pending != null) {
      if (_pendingApiKey == apiKey && (!persist || _pendingPersists)) {
        return pending;
      }
      return pending.then(
        (_) => validateAndGetUserInfo(apiKey, persist: persist),
      );
    }
    _isValidating = true;
    final int token = ++_validationToken;
    _lastValidationError = null;
    final attempt = _validate(apiKey, persist: persist, token: token);
    _pendingValidation = attempt;
    _pendingApiKey = apiKey;
    _pendingPersists = persist;
    return attempt.whenComplete(() {
      if (_validationToken == token) {
        _isValidating = false;
        _pendingValidation = null;
        _pendingApiKey = null;
        _pendingPersists = false;
      }
    });
  }

  static Future<bool> _validate(
    String apiKey, {
    required bool persist,
    required int token,
  }) async {
    try {
      final capability = await ProfileAsyncAuthorization.capture(
        ProfileFeature.cloud,
      );
      debugPrint('TorboxAccountService: Validating API key…');
      final fetch = debugUserInfoFetcher ?? TorboxService.getUserInfo;
      final user = capability == null
          ? await fetch(apiKey)
          : await capability.run(() => fetch(apiKey));
      if (_validationToken != token) {
        debugPrint(
          'TorboxAccountService: Validation result discarded (token mismatch).',
        );
        return false;
      }
      if (capability != null && !capability.isCurrentlyActive) return false;
      Future<void> commit() async {
        if (persist) await StorageService.saveTorboxApiKey(apiKey);
        if (capability == null || capability.isCurrentlyActive) {
          _setCurrentUser(user);
        }
      }

      if (capability == null) {
        await commit();
      } else {
        await capability.runIfCurrent(commit);
      }
      _lastValidationError = null;
      debugPrint('TorboxAccountService: Validation successful.');
      return true;
    } catch (e) {
      if (_validationToken == token) {
        _lastValidationError = validationErrorFor(e);
      }
      debugPrint(
        'TorboxAccountService: Validation unavailable (${e.runtimeType}).',
      );
      return false;
    }
  }

  static Future<bool> isApiKeyValid() async {
    try {
      final apiKey = await StorageService.getTorboxApiKey();
      if (apiKey == null || apiKey.isEmpty) return false;
      return await validateAndGetUserInfo(apiKey, persist: false);
    } on ResourceAuthorizationException {
      return false;
    }
  }

  static void clearUserInfo() {
    debugPrint('TorboxAccountService: Clearing cached user info.');
    _setCurrentUser(null);
    _validationToken++;
    _isValidating = false;
    _pendingValidation = null;
    _pendingApiKey = null;
    _pendingPersists = false;
    _lastValidationError = null;
  }

  static Future<bool> refreshUserInfo() async {
    try {
      final apiKey = await StorageService.getTorboxApiKey();
      if (apiKey == null || apiKey.isEmpty) {
        _setCurrentUser(null);
        return false;
      }
      return await validateAndGetUserInfo(apiKey, persist: false);
    } on ResourceAuthorizationException {
      return false;
    }
  }
}
