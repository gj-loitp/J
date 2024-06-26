import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/exception/eh_site_exception.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:jhentai/src/setting/path_setting.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

import '../exception/upload_exception.dart';
import 'byte_util.dart';

class Log {
  static Logger? _consoleLogger;
  static Logger? _verboseFileLogger;
  static Logger? _warningFileLogger;
  static Logger? _downloadFileLogger;
  static late File _verboseLogFile;
  static late File _waringLogFile;
  static late File _downloadLogFile;

  static final String logDirPath = path.join(PathSetting.getVisibleDir().path, 'logs');

  static Future<void> init() async {
    if (AdvancedSetting.enableLogging.value == false) {
      return;
    }

    if (!await Directory(logDirPath).exists()) {
      await Directory(logDirPath).create();
    }

    LogPrinter devPrinter = PrettyPrinter(stackTraceBeginIndex: 0, methodCount: 6, levelEmojis: {Level.trace: '✔ '});
    LogPrinter prodPrinterWithBox = PrettyPrinter(stackTraceBeginIndex: 0, methodCount: 6, colors: false, printTime: true, levelEmojis: {Level.trace: '✔ '});
    LogPrinter prodPrinterWithoutBox =
        PrettyPrinter(stackTraceBeginIndex: 0, methodCount: 6, colors: false, noBoxingByDefault: true, levelEmojis: {Level.trace: '✔ '});

    _consoleLogger = Logger(printer: devPrinter);

    _verboseLogFile = File(path.join(logDirPath, '${DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now())}.log'));
    _verboseFileLogger = Logger(
      printer: HybridPrinter(prodPrinterWithBox, trace: prodPrinterWithoutBox, debug: prodPrinterWithoutBox, info: prodPrinterWithoutBox),
      filter: EHLogFilter(),
      output: FileOutput(file: File(path.join(logDirPath, '${DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now())}.log'))),
    );

    if (AdvancedSetting.enableVerboseLogging.isTrue) {
      _waringLogFile = File(path.join(logDirPath, '${DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now())}_error.log'));
      _warningFileLogger = Logger(
        level: Level.warning,
        printer: prodPrinterWithBox,
        filter: ProductionFilter(),
        output: FileOutput(file: _waringLogFile),
      );

      _downloadLogFile = File(path.join(logDirPath, '${DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now())}_download.log'));
      _downloadFileLogger = Logger(
        printer: prodPrinterWithoutBox,
        filter: ProductionFilter(),
        output: FileOutput(file: _downloadLogFile),
      );
    }

    debug('init LogUtil success', false);
  }

  /// For actions that print params
  static void trace(Object msg, [bool withStack = false]) {
    _consoleLogger?.t(msg, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.t(msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  /// For actions that is invisible to user
  static void debug(Object msg, [bool withStack = false]) {
    _consoleLogger?.d(msg, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.d(msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  /// For actions that is visible to user
  static void info(Object msg, [bool withStack = false]) {
    _consoleLogger?.i(msg, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.i(msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  static void warning(Object msg, [Object? error, bool withStack = false]) {
    _consoleLogger?.w(msg, stackTrace: withStack ? null : StackTrace.empty);
    _verboseFileLogger?.w(msg, stackTrace: withStack ? null : StackTrace.empty);
    _warningFileLogger?.w(msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  static void error(Object msg, [Object? error, StackTrace? stackTrace]) {
    _consoleLogger?.e(msg, error: error, stackTrace: stackTrace);
    _verboseFileLogger?.e(msg, error: error, stackTrace: stackTrace);
    _warningFileLogger?.e(msg, error: error, stackTrace: stackTrace);
  }

  static void log(OutputEvent event, {bool withStack = true}) {
    _consoleLogger?.log(
      event.level,
      event.origin.message,
      time: event.origin.time,
      error: event.origin.error,
      stackTrace: withStack ? event.origin.stackTrace : StackTrace.empty,
    );
    _verboseFileLogger?.log(
      event.level,
      event.origin.message,
      time: event.origin.time,
      error: event.origin.error,
      stackTrace: withStack ? event.origin.stackTrace : StackTrace.empty,
    );
    _warningFileLogger?.log(
      event.level,
      event.origin.message,
      time: event.origin.time,
      error: event.origin.error,
      stackTrace: withStack ? event.origin.stackTrace : StackTrace.empty,
    );
  }

  static void download(Object msg) {
    _consoleLogger?.t(msg, stackTrace: StackTrace.empty);
    _downloadFileLogger?.t(msg, stackTrace: StackTrace.empty);
  }

  static Future<void> uploadError(dynamic throwable, {dynamic stackTrace, Map<String, dynamic>? extraInfos}) async {
    /// sentry is removed
  }

  static Future<String> getSize() async {
    return compute(
      (logDirPath) {
        Directory logDirectory = Directory(logDirPath);
        return logDirectory.exists().then<int>((exist) {
          if (!exist) {
            return 0;
          }

          return logDirectory.list().fold<int>(0, (previousValue, element) => previousValue += (element as File).lengthSync());
        }).then<String>((totalBytes) => byte2String(totalBytes.toDouble()));
      },
      logDirPath,
    );
  }

  static Future<void> clear() async {
    await _verboseFileLogger?.close();
    await _warningFileLogger?.close();
    await _downloadFileLogger?.close();

    _verboseFileLogger = null;
    _warningFileLogger = null;
    _downloadFileLogger = null;

    if (await Directory(logDirPath).exists()) {
      await Directory(logDirPath).delete(recursive: true);
    }
  }
}

class EHLogFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    if (AdvancedSetting.enableVerboseLogging.isTrue) {
      return event.level.index >= level!.index;
    }
    return event.level.index >= level!.index && event.level != Level.verbose;
  }
}

T callWithParamsUploadIfErrorOccurs<T>(T Function() func, {dynamic params, T? defaultValue}) {
  try {
    return func.call();
  } on Exception catch (e) {
    if (e is DioException || e is EHSiteException) {
      rethrow;
    }

    Log.error('operationFailed'.tr, e);
    Log.uploadError(e, extraInfos: {'params': params});
    if (defaultValue == null) {
      throw NotUploadException(e);
    }
    return defaultValue;
  } on Error catch (e) {
    Log.error('operationFailed'.tr, e);
    Log.uploadError(e, extraInfos: {'params': params});
    if (defaultValue == null) {
      throw NotUploadException(e);
    }
    return defaultValue;
  }
}
