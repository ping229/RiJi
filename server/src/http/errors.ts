/**
 * 统一错误类型：业务错误带稳定错误码，便于客户端按码提示（需求 D12 错误码）。
 */
export class AppError extends Error {
  readonly statusCode: number;
  readonly code: string;
  readonly details?: unknown;

  constructor(code: string, statusCode: number, message: string, details?: unknown) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.statusCode = statusCode;
    this.details = details;
  }

  static badRequest(message: string, details?: unknown): AppError {
    return new AppError('BAD_REQUEST', 400, message, details);
  }

  static unauthorized(message = '未登录或登录已过期'): AppError {
    return new AppError('UNAUTHORIZED', 401, message);
  }

  static forbidden(message = '没有权限执行该操作'): AppError {
    return new AppError('FORBIDDEN', 403, message);
  }

  static notFound(message = '资源不存在'): AppError {
    return new AppError('NOT_FOUND', 404, message);
  }

  static conflict(code: string, message: string, details?: unknown): AppError {
    return new AppError(code, 409, message, details);
  }

  static tooLarge(
    message = '文件超过大小限制',
    code = 'PAYLOAD_TOO_LARGE',
    details?: unknown,
  ): AppError {
    return new AppError(code, 413, message, details);
  }


  static internal(message = '服务端内部错误'): AppError {
    return new AppError('INTERNAL', 500, message);
  }

  /** 日期窗口违规（需求 3.1：超过 7 天只读、未来日期不许写） */
  static dateWindow(reason: 'future' | 'past-window', diaryDate: string, today: string): AppError {
    const message =
      reason === 'future'
        ? `不能写入未来日期（${diaryDate}），今天可写的是 ${today}`
        : `${diaryDate} 已超出 7 天补写窗口（今天 ${today}），该日记为只读`;
    return new AppError('DATE_WINDOW_VIOLATION', 422, message, { reason, diaryDate, today });
  }
}
