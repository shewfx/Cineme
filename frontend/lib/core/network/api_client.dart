import 'package:dio/dio.dart';

/// Typed error from the API envelope (API_CONTRACT). Messages shown to users
/// come from known envelope fields or local fallbacks, never raw bodies.
class ApiError implements Exception {
  const ApiError({
    required this.status,
    required this.code,
    required this.message,
    this.retryable = false,
  });

  final int? status;
  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'ApiError($status $code)';
}

/// Returns the current access token, refreshed by the auth SDK as needed.
typedef AccessTokenSource = Future<String?> Function();

/// The one HTTP client for Cinemé's API: base URL from config, bearer token
/// attached per request, envelope errors mapped to [ApiError].
class ApiClient {
  ApiClient(this._dio, this._token);

  factory ApiClient.create(String baseUrl, AccessTokenSource token) =>
      ApiClient(
        Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
            responseType: ResponseType.json,
          ),
        ),
        token,
      );

  final Dio _dio;
  final AccessTokenSource _token;

  Future<Map<String, dynamic>> get(String path) => _send('GET', path);

  Future<Map<String, dynamic>> post(String path, {Object? body}) =>
      _send('POST', path, body: body);

  /// Private mutations carry the caller's UUID [idempotencyKey]; a retry of
  /// the same command must reuse it.
  Future<Map<String, dynamic>> patch(
    String path, {
    required Object body,
    required String idempotencyKey,
  }) => _send(
    'PATCH',
    path,
    body: body,
    headers: {'Idempotency-Key': idempotencyKey},
  );

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final token = await _token();
    try {
      final response = await _dio.request<Object?>(
        path,
        data: body,
        options: Options(
          method: method,
          headers: {
            ...headers,
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) throw _malformed(response.statusCode);
      return data;
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  static ApiError _malformed(int? status) => ApiError(
    status: status,
    code: 'MALFORMED_RESPONSE',
    message: 'Cinemé sent an unexpected response.',
  );

  static ApiError _map(DioException e) {
    final response = e.response;
    if (response == null) {
      return const ApiError(
        status: null,
        code: 'NETWORK_ERROR',
        message: "Couldn't reach Cinemé. Check your connection and try again.",
        retryable: true,
      );
    }
    final data = response.data;
    final error = data is Map<String, dynamic> ? data['error'] : null;
    if (error is Map<String, dynamic> &&
        error['code'] is String &&
        error['message'] is String) {
      return ApiError(
        status: response.statusCode,
        code: error['code'] as String,
        message: error['message'] as String,
        retryable: error['retryable'] == true,
      );
    }
    return _malformed(response.statusCode);
  }
}
