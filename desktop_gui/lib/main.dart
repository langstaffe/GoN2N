import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

// Keep app UI text on this Windows UI font so Chinese glyph weight stays stable.
const _appFontFamily = 'Microsoft YaHei UI';
const _fallbackAppVersion = 'v0.1.0';
const _projectHomeUrl = 'https://github.com/langstaffe/GoN2N';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GoN2NApp(initialDarkMode: _readInitialDarkMode()));
}

bool _readInitialDarkMode() {
  try {
    final home = Platform.environment[Platform.isWindows ? 'APPDATA' : 'HOME'];
    if (home == null || home.isEmpty) return false;
    final path = Platform.isWindows
        ? '$home\\GoN2N\\settings.json'
        : '$home/.config/gon2n/settings.json';
    final file = File(path);
    if (!file.existsSync()) return false;
    final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return value['darkMode'] as bool? ?? false;
  } catch (_) {
    return false;
  }
}

class GoN2NApp extends StatefulWidget {
  const GoN2NApp({
    required this.initialDarkMode,
    super.key,
  });

  final bool initialDarkMode;

  @override
  State<GoN2NApp> createState() => _GoN2NAppState();
}

class _GoN2NAppState extends State<GoN2NApp> {
  late bool _darkMode = widget.initialDarkMode;

  void _setDarkMode(bool value) {
    setState(() => _darkMode = value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoN2N',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: _appFontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2563eb),
          brightness: Brightness.light,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        fontFamily: _appFontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff93c5fd),
          brightness: Brightness.dark,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        useMaterial3: true,
      ),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      home: ConnectionPage(
        darkMode: _darkMode,
        onDarkModeChanged: _setDarkMode,
      ),
    );
  }
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    required this.darkMode,
    required this.onDarkModeChanged,
    super.key,
  });

  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  static const _shareFormat = 'gon2n.share.v2';
  static const _legacyShareFormat = 'gon2n.share.v1';
  static const _shareUriPrefix = 'gon2n:';
  static const _defaultAddressSubnet = '10.239.180.0/24';
  static const _diagnosticPort = 51875;
  static const _speedTestBytes = 4 * 1024 * 1024;
  static const _diagnosticResultTtl = Duration(seconds: 30);
  static const _maxReconnectDelay = Duration(seconds: 30);

  final _formKey = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _port = TextEditingController(text: '7777');
  final _community = TextEditingController();
  final _nickname = TextEditingController();
  final _memberServiceUrl = TextEditingController();
  final _address = TextEditingController();
  final _key = TextEditingController();
  final _memberServiceKey = TextEditingController();
  final _edgePath = TextEditingController();
  final _logText = TextEditingController();
  final _logs = <String>[];
  bool _compactLogs = true;
  double _splitFraction = 55 / 100;
  double _rightPanelFraction = 0.50;
  bool _tapReadyLogged = false;
  bool _supernodeReadyLogged = false;

  Process? _edge;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  bool _connecting = false;
  bool _obscureKey = true;
  bool _obscureMemberServiceKey = true;
  bool _advancedSettingsExpanded = false;
  bool _exitConfirmationOpen = false;
  bool _exitInProgress = false;
  bool _manualDisconnectRequested = false;
  bool _forceRelay = true;
  bool _preferTapMetric = true;
  bool _verboseEdgeLogs = false;
  String? _deviceId;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _heartbeatInFlight = false;
  int _heartbeatFailureCount = 0;
  bool _heartbeatUnavailableLogged = false;
  ServerSocket? _tcpDiagnosticServer;
  RawDatagramSocket? _udpDiagnosticServer;
  bool _diagnosticStarting = false;
  AppLifecycleListener? _lifecycleListener;
  List<_OnlineMember> _members = const [];
  final _connectionModes = <String, String>{};
  final _checkResults = <String, _NetworkCheckResult>{};
  final _speedTestResults = <String, _SpeedTestResult>{};
  final _checkResultTimers = <String, Timer>{};
  final _speedTestResultTimers = <String, Timer>{};
  bool _checkingNetwork = false;
  bool get _edgeRunning => _edge != null;
  bool get _connected => _status == ConnectionStatus.connected;
  bool get _canStartConnection => !_connecting && !_edgeRunning;

  String get _connectButtonLabel {
    if (_edgeRunning) return '断开连接';
    return '连接';
  }

  IconData get _statusIcon {
    return switch (_status) {
      ConnectionStatus.connected => Icons.cloud_done,
      ConnectionStatus.connecting => Icons.sync,
      ConnectionStatus.error => Icons.error_outline,
      ConnectionStatus.disconnected => Icons.cloud_off,
    };
  }

  Color _statusColor(BuildContext context) {
    return switch (_status) {
      ConnectionStatus.connected => Colors.green,
      ConnectionStatus.connecting => Theme.of(context).colorScheme.primary,
      ConnectionStatus.error => Colors.red,
      ConnectionStatus.disconnected => Colors.grey,
    };
  }

  String get _statusLabel {
    return switch (_status) {
      ConnectionStatus.connected => '已连接',
      ConnectionStatus.connecting => '连接中',
      ConnectionStatus.error => '报错',
      ConnectionStatus.disconnected => '未连接',
    };
  }

  @override
  void initState() {
    super.initState();
    _edgePath.text = _defaultEdgePath();
    _nickname.text = _defaultNickname();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: _confirmExit,
    );
    unawaited(_loadSettings());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureTapAdapter());
    });
  }

  @override
  void dispose() {
    _edge?.kill();
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    for (final timer in _checkResultTimers.values) {
      timer.cancel();
    }
    for (final timer in _speedTestResultTimers.values) {
      timer.cancel();
    }
    _lifecycleListener?.dispose();
    _stopDiagnosticServer();
    unawaited(_restoreTapMetric());
    unawaited(_releaseMemberLease());
    _server.dispose();
    _port.dispose();
    _community.dispose();
    _nickname.dispose();
    _memberServiceUrl.dispose();
    _address.dispose();
    _key.dispose();
    _memberServiceKey.dispose();
    _edgePath.dispose();
    _logText.dispose();
    super.dispose();
  }

  Future<File> _settingsFile() async {
    final home = Platform.environment[Platform.isWindows ? 'APPDATA' : 'HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('无法找到用户配置目录');
    }
    final directory = Directory(
      Platform.isWindows ? '$home\\GoN2N' : '$home/.config/gon2n',
    );
    await directory.create(recursive: true);
    return File(
      Platform.isWindows
          ? '${directory.path}\\settings.json'
          : '${directory.path}/settings.json',
    );
  }

  Future<void> _loadSettings() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return;
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _server.text = value['server'] as String? ?? '';
        _port.text = value['port'] as String? ?? '7777';
        _community.text = value['community'] as String? ?? '';
        _nickname.text = value['nickname'] as String? ?? _nickname.text.trim();
        _memberServiceUrl.text = value['memberServiceUrl'] as String? ?? '';
        _address.text = _displayAddress(value['address'] as String? ?? '');
        _key.text = value['sharedKey'] as String? ?? '';
        _memberServiceKey.text = value['memberServiceKey'] as String? ?? '';
        _edgePath.text = _resolveSavedEdgePath(value['edgePath'] as String?);
        _forceRelay = value['forceRelay'] as bool? ?? true;
        _preferTapMetric = value['preferTapMetric'] as bool? ?? true;
        _verboseEdgeLogs = value['verboseEdgeLogs'] as bool? ?? false;
        _deviceId = value['deviceId'] as String? ?? _generateDeviceId();
      });
    } catch (error) {
      _appendLog('读取配置失败：$error');
    }
  }

  Future<void> _saveSettings({bool? darkMode}) async {
    final file = await _settingsFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      '${encoder.convert({
            'server': _server.text.trim(),
            'port': _port.text.trim(),
            'community': _community.text.trim(),
            'nickname': _nickname.text.trim(),
            'memberServiceUrl': _memberServiceUrl.text.trim(),
            'address': _address.text.trim(),
            'sharedKey': _key.text,
            'memberServiceKey': _memberServiceKey.text,
            'edgePath': _edgePath.text.trim(),
            'forceRelay': _forceRelay,
            'preferTapMetric': _preferTapMetric,
            'verboseEdgeLogs': _verboseEdgeLogs,
            'deviceId': _deviceId ??= _generateDeviceId(),
            'darkMode': darkMode ?? widget.darkMode,
          })}\n',
    );
  }

  Future<void> _setDarkMode(bool value) async {
    widget.onDarkModeChanged(value);
    await _saveSettings(darkMode: value);
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() {
      _logs.add(
          '[${DateTime.now().toLocal().toIso8601String().substring(11, 19)}] $line');
      if (_logs.length > 1000) _logs.removeAt(0);
      _syncLogText();
    });
  }

  void _handleEdgeLog(String line) {
    _appendLog(line);
    final lower = line.toLowerCase();
    _updateConnectionModeFromEdgeLog(line);
    if (!_tapReadyLogged &&
        (lower.contains('open device') ||
            lower.contains('created local tap device ip'))) {
      _tapReadyLogged = true;
      final localIp = _displayAddress(_address.text);
      _appendLog(localIp.isEmpty ? 'TAP 网卡已就绪' : 'TAP 网卡已就绪：$localIp');
      unawaited(_applyTapMetricPreference());
    }
    if (lower.contains('authentication error') ||
        lower.contains('mac or ip address already in use')) {
      unawaited(_handleAuthenticationError());
      return;
    }
    if (lower.contains('rx register_super_ack from') ||
        lower.contains('received register_super_ack')) {
      if (!_supernodeReadyLogged) {
        _supernodeReadyLogged = true;
        _appendLog('已连接到 supernode');
      }
      _markEdgeConnected();
      return;
    }
    if (lower.contains('error:') ||
        lower.contains('authentication error') ||
        lower.contains('supernode not responding')) {
      if (mounted && _edgeRunning) {
        setState(() => _status = ConnectionStatus.error);
      }
    }
  }

  void _updateConnectionModeFromEdgeLog(String line) {
    final match = RegExp(
      r'peer\s+([^\s]+)\s+changed\s+\[[^\]]+\]\s+->\s+\[([^:\]]+):\d+\]',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return;
    final peer = match.group(1);
    final host = match.group(2);
    if (peer == null || host == null) return;
    final member = _memberForPeerEndpoint(peer, host);
    if (member == null) return;
    final mode = _isSupernodeEndpoint(host) ? '中继' : '直连';
    _setMemberConnectionMode(member.deviceId, mode);
  }

  _OnlineMember? _memberForPeerEndpoint(String peer, String host) {
    final peerIp = _normalizePeerAddress(peer);
    final hostIp = _normalizePeerAddress(host);
    for (final member in _members) {
      if (member.deviceId == _deviceId) continue;
      if (member.ip == peerIp || member.ip == hostIp) return member;
    }
    final others =
        _members.where((member) => member.deviceId != _deviceId).toList();
    if (others.length == 1) return others.single;
    return null;
  }

  String _normalizePeerAddress(String value) {
    final trimmed = value.trim();
    final bracketedIpv6 =
        RegExp(r'^\[([^\]]+)\](?::\d+)?$').firstMatch(trimmed);
    if (bracketedIpv6 != null) return bracketedIpv6.group(1) ?? trimmed;
    final ipv4WithPort =
        RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?$').firstMatch(trimmed);
    if (ipv4WithPort != null) return ipv4WithPort.group(1) ?? trimmed;
    return trimmed;
  }

  bool _isSupernodeEndpoint(String host) {
    final supernodeHost = _normalizePeerAddress(_server.text.trim());
    final endpointHost = _normalizePeerAddress(host);
    return endpointHost == supernodeHost;
  }

  void _setMemberConnectionMode(String deviceId, String mode) {
    if (mounted) {
      setState(() => _applyMemberConnectionMode(deviceId, mode));
    } else {
      _applyMemberConnectionMode(deviceId, mode);
    }
  }

  void _applyMemberConnectionMode(String deviceId, String mode) {
    _connectionModes[deviceId] = mode;
    final result = _checkResults[deviceId];
    if (result != null && !result.testing) {
      _checkResults[deviceId] = result.withMode(mode);
    }
  }

  void _markEdgeConnected() {
    if (!mounted ||
        !_edgeRunning ||
        _status == ConnectionStatus.connected ||
        _status == ConnectionStatus.error) {
      return;
    }
    _reconnectAttempts = 0;
    setState(() => _status = ConnectionStatus.connected);
    unawaited(_applyTapMetricPreference());
    unawaited(_startDiagnosticServer());
    _startHeartbeat();
  }

  Future<void> _handleAuthenticationError() async {
    if (!mounted) return;
    final process = _edge;
    setState(() {
      _status = ConnectionStatus.error;
      _edge = null;
    });
    process?.kill(
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigint);
    _heartbeatTimer?.cancel();
    _stopDiagnosticServer();
    unawaited(_restoreTapMetric());
    unawaited(_releaseMemberLease());

    const message = '连接被 n2n 服务拒绝，可立即重试连接。';
    _appendLog(message);
    _showError(message);
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
  }

  void _scheduleReconnect(String reason) {
    if (!mounted || _exitInProgress || _manualDisconnectRequested) return;
    if (_reconnectTimer?.isActive == true || _connecting || _edgeRunning) {
      return;
    }
    final seconds = _nextReconnectDelaySeconds();
    _reconnectAttempts++;
    final delay = Duration(seconds: seconds);
    _appendLog(seconds == 0 ? '$reason，立即自动重连' : '$reason，$seconds 秒后自动重连');
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!mounted || _exitInProgress || _manualDisconnectRequested) return;
      unawaited(_connect(isAutoReconnect: true));
    });
  }

  int _nextReconnectDelaySeconds() {
    if (_reconnectAttempts == 0) return 0;
    if (_reconnectAttempts == 1) return 1;
    return min((_reconnectAttempts - 1) * 3, _maxReconnectDelay.inSeconds);
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
      _syncLogText();
    });
  }

  void _syncLogText() {
    final text = _visibleLogs().join('\n');
    _logText.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  List<String> _visibleLogs() {
    if (!_compactLogs) return List<String>.of(_logs);
    return _logs.where(_isCompactLogLine).toList();
  }

  bool _isCompactLogLine(String line) {
    final lower = line.toLowerCase();

    if (lower.contains('error') ||
        lower.contains('warning') ||
        lower.contains('failed') ||
        lower.contains('timeout') ||
        lower.contains('authentication error') ||
        lower.contains('mac or ip address already in use') ||
        lower.contains('not released yet') ||
        lower.contains('no windows tap devices found')) {
      return true;
    }

    if (line.contains('正在连接') ||
        line.contains('使用 edge') ||
        line.contains('edge 已启动') ||
        line.contains('edge 已退出') ||
        line.contains('正在断开连接') ||
        line.contains('虚拟 IP') ||
        line.contains('n2n服务器正在释放ip') ||
        line.contains('虚拟网卡优先级') ||
        line.contains('TAP-Windows') ||
        line.contains('TAP 网卡') ||
        line.contains('成员服务') ||
        line.contains('网络测试服务')) {
      return true;
    }

    return lower.contains('已连接到 supernode');
  }

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: _logText.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('运行日志已复制')),
    );
  }

  Future<void> _copyMemberIp(String ip) async {
    await Clipboard.setData(ClipboardData(text: ip));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 IP：$ip')),
    );
  }

  void _ensureGeneratedFields() {
    var changed = false;
    if (_community.text.trim().isEmpty) {
      _community.text = _generateToken('g', 12);
      changed = true;
    }
    if (_key.text.isEmpty) {
      _key.text = _generateToken('', 24);
      changed = true;
    }
    if (_nickname.text.trim().isEmpty) {
      _nickname.text = _defaultNickname();
      changed = true;
    }
    if (_address.text.trim().isEmpty) {
      _address.text = _generateAddress();
      changed = true;
    }
    if (changed) {
      _appendLog('已自动生成社区名、共享密钥或虚拟 IP');
    }
  }

  String _generateToken(String prefix, int length) {
    const alphabet =
        'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    final value = List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    return '$prefix$value';
  }

  Future<void> _waitForEdgeExit(Process process) async {
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _appendLog('edge 正在退出，稍后可重新连接');
    }
  }

  Map<String, Object?> _sharePayload() {
    final subnet =
        _addressSubnet(_address.text.trim()) ?? _defaultAddressSubnet;
    return {
      'format': _shareFormat,
      'server': _server.text.trim(),
      'port': _port.text.trim(),
      'community': _community.text.trim(),
      'addressSubnet': subnet,
      'memberServiceUrl': _memberServiceUrl.text.trim(),
      'sharedKey': _key.text,
      'memberServiceKey': _memberServiceKey.text,
      'forceRelay': _forceRelay,
      'preferTapMetric': _preferTapMetric,
      'verboseEdgeLogs': _verboseEdgeLogs,
    };
  }

  Future<bool> _leaseMemberAddress() async {
    final uri = _memberServiceUri('/v1/lease');
    if (uri == null) {
      _showError('成员服务地址无效');
      return false;
    }
    try {
      final response = await _postMemberJson(uri, {
        'networkId': _networkId(),
        'deviceId': _deviceId ??= _generateDeviceId(),
        'nickname': _nickname.text.trim(),
        'requestedIp': _address.text.trim(),
        'subnet': _addressSubnet(_address.text.trim()) ?? _defaultAddressSubnet,
      });
      if (response['ip'] is String) {
        setState(() {
          _address.text = _displayAddress(response['ip'] as String);
          _members = _membersFromJson(response['members']);
        });
        return true;
      }
      _showError('成员服务没有返回可用 IP');
      return false;
    } catch (error) {
      _appendLog('成员服务连接失败：$error');
      _showError('成员服务连接失败，请确认服务器已启动 gon2n member-server。');
      return false;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatFailureCount = 0;
    _heartbeatUnavailableLogged = false;
    unawaited(_sendHeartbeat());
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_sendHeartbeat()),
    );
  }

  Future<void> _sendHeartbeat() async {
    if (!_edgeRunning || _heartbeatInFlight) return;
    final uri = _memberServiceUri('/v1/heartbeat');
    if (uri == null) return;
    _heartbeatInFlight = true;
    try {
      final response = await _postMemberJson(uri, {
        'networkId': _networkId(),
        'deviceId': _deviceId ??= _generateDeviceId(),
        'nickname': _nickname.text.trim(),
        'requestedIp': _address.text.trim(),
        'subnet': _addressSubnet(_address.text.trim()) ?? _defaultAddressSubnet,
      });
      if (!mounted) return;
      setState(() {
        if (response['ip'] is String) {
          _address.text = _displayAddress(response['ip'] as String);
        }
        _members = _membersFromJson(response['members']);
      });
      if (_heartbeatFailureCount > 0 || _heartbeatUnavailableLogged) {
        _appendLog('成员服务已恢复');
      }
      _heartbeatFailureCount = 0;
      _heartbeatUnavailableLogged = false;
    } catch (error) {
      _heartbeatFailureCount++;
      _appendLog('成员心跳失败：$error');
      if (_heartbeatFailureCount >= 3 && !_heartbeatUnavailableLogged) {
        _heartbeatUnavailableLogged = true;
        _appendLog('成员服务暂时不可用，在线成员列表可能延迟更新');
      }
    } finally {
      _heartbeatInFlight = false;
    }
  }

  Future<void> _releaseMemberLease() async {
    final uri = _memberServiceUri('/v1/release');
    if (uri == null || _deviceId == null) return;
    try {
      await _postMemberJson(uri, {
        'networkId': _networkId(),
        'deviceId': _deviceId,
      });
    } catch (_) {
      // Lease expiry on the server will clean up abnormal disconnects.
    }
    if (mounted) {
      setState(() {
        _members = const [];
        _connectionModes.clear();
      });
    }
  }

  Future<Map<String, dynamic>> _postMemberJson(
    Uri uri,
    Map<String, Object?> payload,
  ) async {
    final client = HttpClient();
    const timeout = Duration(seconds: 10);
    client.connectionTimeout = timeout;
    try {
      final request = await client.postUrl(uri).timeout(
            timeout,
          );
      request.headers.contentType = ContentType.json;
      request.write(
          jsonEncode(_sealMemberPayload(payload, _memberServiceKey.text)));
      final response = await request.close().timeout(
            timeout,
          );
      final body = await response.transform(utf8.decoder).join().timeout(
            timeout,
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(body.isEmpty ? response.reasonPhrase : body);
      }
      if (body.trim().isEmpty) return <String, dynamic>{};
      return _openMemberPayload(body, _memberServiceKey.text);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _exportShareConfig() async {
    _ensureGeneratedFields();
    if (_server.text.trim().isEmpty || _port.text.trim().isEmpty) {
      _showError('请先填写服务器地址和端口');
      return;
    }
    await _saveSettings();
    final text = _encodeSharePayload(_sharePayload());
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('节点信息已导出到剪贴板')),
    );
  }

  Future<void> _importShareConfig() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) {
      _showError('剪切板为空，无法导入');
      return;
    }
    try {
      final value = _decodeSharePayload(text);
      final format = value['format'];
      if (format != _shareFormat && format != _legacyShareFormat) {
        throw const FormatException('不是 GoN2N 分享配置');
      }
      setState(() {
        _server.text = value['server'] as String? ?? '';
        _port.text = value['port'] as String? ?? '7777';
        _community.text = value['community'] as String? ?? '';
        _memberServiceUrl.text = value['memberServiceUrl'] as String? ?? '';
        _address.text = _generateAddress(value['addressSubnet'] as String? ??
            _addressSubnet(value['address'] as String? ?? ''));
        _key.text = value['sharedKey'] as String? ?? '';
        _memberServiceKey.text = value['memberServiceKey'] as String? ?? '';
        _forceRelay = value['forceRelay'] as bool? ?? true;
        _preferTapMetric = value['preferTapMetric'] as bool? ?? true;
        _verboseEdgeLogs = value['verboseEdgeLogs'] as bool? ?? false;
      });
      _ensureGeneratedFields();
      await _saveSettings();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('节点信息已从剪贴板导入')),
      );
    } catch (error) {
      _showError('导入失败：剪切板不是有效的 GoN2N 节点信息');
    }
  }

  String _encodeSharePayload(Map<String, Object?> payload) {
    final json = jsonEncode(payload);
    final encoded = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    return '$_shareUriPrefix$encoded';
  }

  Map<String, dynamic> _decodeSharePayload(String text) {
    final token = _extractShareToken(text);
    if (token != null) {
      final padded =
          token.padRight(token.length + (4 - token.length % 4) % 4, '=');
      final json = utf8.decode(base64Url.decode(padded));
      return jsonDecode(json) as Map<String, dynamic>;
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  String? _extractShareToken(String text) {
    final match = RegExp(r'gon2n:([A-Za-z0-9_-]+)', caseSensitive: false)
        .firstMatch(text);
    return match?.group(1);
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) return '此项不能为空';
    return null;
  }

  String? _validatePort(String? value) {
    final port = int.tryParse(value ?? '');
    if (port == null || port < 1 || port > 65535) return '请输入 1-65535 的端口';
    return null;
  }

  String? _validateCommunity(String? value) {
    final required = _required(value);
    if (required != null) return required;
    if (utf8.encode(value!.trim()).length > 20) return '社区名不能超过 20 字节';
    return null;
  }

  String? _validateAddress(String? value) {
    final required = _required(value);
    if (required != null) return required;
    final pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$');
    if (!pattern.hasMatch(value!.trim())) return '请输入类似 10.239.180.10 的地址';
    return null;
  }

  String _generateAddress([String? subnet]) {
    final prefix = _addressPrefix(subnet) ??
        _addressPrefix(_addressSubnet(_address.text.trim())) ??
        _addressPrefix(_defaultAddressSubnet)!;
    final host = Random.secure().nextInt(240) + 10;
    return '$prefix.$host';
  }

  String? _addressPrefix(String? subnet) {
    if (subnet == null || subnet.trim().isEmpty) return null;
    final match = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.0/24$')
        .firstMatch(subnet.trim());
    if (match == null) return null;
    final octets = [
      int.tryParse(match.group(1)!),
      int.tryParse(match.group(2)!),
      int.tryParse(match.group(3)!),
    ];
    if (octets.any((value) => value == null || value < 0 || value > 255)) {
      return null;
    }
    return '${octets[0]}.${octets[1]}.${octets[2]}';
  }

  String? _addressSubnet(String address) {
    final match = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}(/24)?$')
        .firstMatch(address.trim());
    if (match == null) return null;
    final octets = [
      int.tryParse(match.group(1)!),
      int.tryParse(match.group(2)!),
      int.tryParse(match.group(3)!),
    ];
    if (octets.any((value) => value == null || value < 0 || value > 255)) {
      return null;
    }
    return '${octets[0]}.${octets[1]}.${octets[2]}.0/24';
  }

  String _edgeAddress() {
    final address = _address.text.trim();
    return address.contains('/') ? address : '$address/24';
  }

  String _displayAddress(String address) {
    return address.trim().replaceFirst(RegExp(r'/24$'), '');
  }

  Uri? _memberServiceUri(String path) {
    final explicit = _memberServiceUrl.text.trim();
    if (explicit.isNotEmpty) {
      final base = explicit.endsWith('/')
          ? explicit.substring(0, explicit.length - 1)
          : explicit;
      return Uri.tryParse('$base$path');
    }
    final host = _server.text.trim();
    if (host.isEmpty) return null;
    return Uri.tryParse('http://$host:51874$path');
  }

  String _networkId() {
    return _fnv1a64('${_community.text.trim()}\x00${_key.text}');
  }

  String _fnv1a64(String value) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * prime) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  String _defaultNickname() {
    final name = Platform.environment['COMPUTERNAME'] ??
        Platform.environment['HOSTNAME'] ??
        Platform.environment['USERNAME'] ??
        Platform.environment['USER'] ??
        'GoN2N';
    return name.trim().isEmpty ? 'GoN2N' : name.trim();
  }

  List<_OnlineMember> _membersFromJson(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map<String, dynamic>>()
        .map(_OnlineMember.fromJson)
        .toList(growable: false);
  }

  Future<void> _pasteInto(TextEditingController controller) async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text;
    if (text == null || text.isEmpty) return;

    final selection = controller.selection;
    if (!selection.isValid) {
      controller.text = text;
      controller.selection = TextSelection.collapsed(offset: text.length);
      return;
    }

    final newValue = controller.value.replaced(selection, text);
    controller.value = newValue.copyWith(
      selection: TextSelection.collapsed(
        offset: selection.start + text.length,
      ),
      composing: TextRange.empty,
    );
  }

  Widget _pasteButton(TextEditingController controller) {
    return IconButton(
      tooltip: '粘贴',
      onPressed: _edgeRunning ? null : () => _pasteInto(controller),
      icon: const Icon(Icons.content_paste_outlined),
    );
  }

  Widget _contextMenuBuilder(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    return AdaptiveTextSelectionToolbar.editableText(
      editableTextState: editableTextState,
    );
  }

  Future<void> _startDiagnosticServer() async {
    if (_diagnosticStarting ||
        _tcpDiagnosticServer != null ||
        _udpDiagnosticServer != null) {
      return;
    }
    final localIp = _displayAddress(_address.text);
    if (localIp.isEmpty) return;
    _diagnosticStarting = true;
    Object? lastError;
    try {
      for (var attempt = 1; attempt <= 12; attempt++) {
        if (!mounted || !_edgeRunning || _status == ConnectionStatus.error) {
          return;
        }
        ServerSocket? tcpServer;
        RawDatagramSocket? udpServer;
        try {
          final address = InternetAddress(localIp);
          tcpServer = await ServerSocket.bind(
            address,
            _diagnosticPort,
            shared: true,
          );
          udpServer = await RawDatagramSocket.bind(
            address,
            _diagnosticPort,
            reuseAddress: true,
          );
          tcpServer.listen(_handleDiagnosticTcpClient);
          udpServer.listen((event) {
            if (event != RawSocketEvent.read) return;
            final datagram = udpServer!.receive();
            if (datagram == null) return;
            final message = utf8.decode(datagram.data, allowMalformed: true);
            if (message.startsWith('gon2n-udp-ping:')) {
              final nonce = message.substring('gon2n-udp-ping:'.length);
              udpServer.send(
                utf8.encode('gon2n-udp-pong:$nonce'),
                datagram.address,
                datagram.port,
              );
            } else if (message.startsWith('gon2n-discovery:')) {
              final nonce = message.substring('gon2n-discovery:'.length);
              udpServer.send(
                utf8.encode('gon2n-discovery-pong:$nonce:$localIp'),
                datagram.address,
                datagram.port,
              );
            }
          });

          _tcpDiagnosticServer = tcpServer;
          _udpDiagnosticServer = udpServer;
          await _ensureDiagnosticFirewallRules(localIp);
          _appendLog('网络测试服务已监听 $localIp:$_diagnosticPort');
          return;
        } catch (error) {
          lastError = error;
          await tcpServer?.close();
          udpServer?.close();
          if (attempt < 12) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      }
      _appendLog('网络测试服务启动失败：$lastError');
    } finally {
      _diagnosticStarting = false;
    }
  }

  void _handleDiagnosticTcpClient(Socket socket) {
    unawaited(() async {
      try {
        final data = await socket.first.timeout(const Duration(seconds: 3));
        final message = utf8.decode(data, allowMalformed: true);
        if (message.startsWith('gon2n-tcp-ping')) {
          socket.write('gon2n-tcp-pong');
          await socket.flush();
        } else if (message.startsWith('gon2n-speed-download')) {
          final chunk = List<int>.filled(16 * 1024, 0x47);
          var remaining = _speedTestBytes;
          while (remaining > 0) {
            final size = remaining < chunk.length ? remaining : chunk.length;
            socket.add(size == chunk.length ? chunk : chunk.sublist(0, size));
            remaining -= size;
          }
          await socket.flush();
        }
      } catch (_) {
        // Ignore malformed or timed out diagnostics requests.
      } finally {
        await socket.close();
      }
    }());
  }

  void _stopDiagnosticServer() {
    _tcpDiagnosticServer?.close();
    _udpDiagnosticServer?.close();
    _tcpDiagnosticServer = null;
    _udpDiagnosticServer = null;
    unawaited(_removeDiagnosticFirewallRules());
  }

  Future<void> _applyTapMetricPreference() async {
    if (!Platform.isWindows || !_preferTapMetric) return;
    final localIp = _displayAddress(_address.text);
    final escapedIp = localIp.replaceAll("'", "''");
    Object? lastError;
    for (var attempt = 0; attempt < 8; attempt++) {
      if (!_edgeRunning || !_preferTapMetric) return;
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "\$ip = '$escapedIp'; "
            r"$alias = (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ip -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty InterfaceAlias); "
            r"if (-not $alias) { "
            r"$adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -like '*TAP-Windows Adapter V9*' -and $_.Status -ne 'Disabled' } | Select-Object -First 1; "
            r"if ($adapter) { $alias = $adapter.Name } "
            r"}; "
            r"if (-not $alias) { throw 'No TAP-Windows adapter found' }; "
            r"Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 1 -ErrorAction Stop; "
            r"Write-Output $alias",
      ]);
      if (result.exitCode == 0) {
        final alias = result.stdout.toString().trim();
        _appendLog(alias.isEmpty ? '虚拟网卡优先级已提高' : '虚拟网卡优先级已提高：$alias');
        return;
      }
      lastError = result.stderr;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    _appendLog('提高虚拟网卡优先级失败：$lastError');
  }

  Future<void> _restoreTapMetric() async {
    if (!Platform.isWindows) return;
    final localIp = _displayAddress(_address.text);
    final escapedIp = localIp.replaceAll("'", "''");
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "\$ip = '$escapedIp'; "
          r"$alias = (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ip -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty InterfaceAlias); "
          r"if (-not $alias) { "
          r"$adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -like '*TAP-Windows Adapter V9*' -and $_.Status -ne 'Disabled' } | Sort-Object @{ Expression = { if ($_.Status -eq 'Up') { 0 } else { 1 } } }, ifIndex | Select-Object -First 1; "
          r"if ($adapter) { $alias = $adapter.Name } "
          r"}; "
          r"if ($alias) { Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue }",
    ]);
    if (result.exitCode == 0) {
      _appendLog('虚拟网卡优先级已恢复默认');
    }
  }

  Future<void> _ensureDiagnosticFirewallRules(String localIp) async {
    if (!Platform.isWindows) return;
    final subnet = _addressSubnet(localIp) ?? _defaultAddressSubnet;
    await _removeDiagnosticFirewallRules();
    for (final protocol in const ['TCP', 'UDP']) {
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "New-NetFirewallRule -DisplayName 'GoN2N Diagnostic $protocol' "
            "-Direction Inbound -Action Allow -Protocol $protocol "
            "-LocalAddress '$localIp' -LocalPort $_diagnosticPort "
            "-RemoteAddress '$subnet' | Out-Null",
      ]);
    }
  }

  Future<void> _removeDiagnosticFirewallRules() async {
    if (!Platform.isWindows) return;
    await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Remove-NetFirewallRule -DisplayName 'GoN2N Diagnostic TCP' "
          "-ErrorAction SilentlyContinue; "
          "Remove-NetFirewallRule -DisplayName 'GoN2N Diagnostic UDP' "
          "-ErrorAction SilentlyContinue",
    ]);
  }

  Future<void> _runNetworkChecks() async {
    if (!_connected || _checkingNetwork) return;
    final targets =
        _members.where((member) => member.deviceId != _deviceId).toList();
    if (targets.isEmpty) {
      _showError('没有可测试的其他在线成员');
      return;
    }

    setState(() => _checkingNetwork = true);
    try {
      setState(() {
        for (final member in targets) {
          _checkResultTimers.remove(member.deviceId)?.cancel();
          _checkResults[member.deviceId] = _NetworkCheckResult.testing();
        }
      });

      await Future.wait(targets.map((member) async {
        final result = await _checkMember(member);
        if (!mounted) return;
        setState(() {
          _checkResults[member.deviceId] = result;
        });
        _expireNetworkCheckResult(member.deviceId);
      }));
    } finally {
      if (mounted) setState(() => _checkingNetwork = false);
    }
  }

  Future<_NetworkCheckResult> _checkMember(_OnlineMember member) async {
    final tcp = await _checkTcp(member.ip);
    final udp = await _checkUdp(member.ip);
    final mode = _connectionModeFor(member);
    return _NetworkCheckResult(
      testing: false,
      latencyMs: udp.averageMs ?? tcp.latencyMs,
      udpLossPercent: udp.lossPercent,
      tcpOk: tcp.ok,
      udpOk: udp.ok,
      mode: mode,
      checkedAt: DateTime.now(),
    );
  }

  void _expireNetworkCheckResult(String deviceId) {
    _checkResultTimers.remove(deviceId)?.cancel();
    _checkResultTimers[deviceId] = Timer(_diagnosticResultTtl, () {
      if (!mounted) return;
      setState(() {
        _checkResults.remove(deviceId);
        _checkResultTimers.remove(deviceId);
      });
    });
  }

  void _expireSpeedTestResult(String deviceId) {
    _speedTestResultTimers.remove(deviceId)?.cancel();
    _speedTestResultTimers[deviceId] = Timer(_diagnosticResultTtl, () {
      if (!mounted) return;
      setState(() {
        _speedTestResults.remove(deviceId);
        _speedTestResultTimers.remove(deviceId);
      });
    });
  }

  Future<void> _runSpeedTest(_OnlineMember member) async {
    if (!_connected ||
        member.deviceId == _deviceId ||
        _speedTestResults[member.deviceId]?.testing == true) {
      return;
    }
    _speedTestResultTimers.remove(member.deviceId)?.cancel();
    setState(() {
      _speedTestResults[member.deviceId] = _SpeedTestResult.testing();
    });
    final result = await _testDownloadSpeed(member.ip);
    if (!mounted) return;
    setState(() {
      _speedTestResults[member.deviceId] = result;
    });
    _expireSpeedTestResult(member.deviceId);
  }

  Future<_SpeedTestResult> _testDownloadSpeed(String ip) async {
    Socket? socket;
    final stopwatch = Stopwatch();
    var received = 0;
    try {
      socket = await Socket.connect(
        ip,
        _diagnosticPort,
        timeout: const Duration(seconds: 5),
      );
      socket.write('gon2n-speed-download');
      await socket.flush();
      stopwatch.start();
      await for (final data in socket.timeout(const Duration(seconds: 20))) {
        received += data.length;
        if (received >= _speedTestBytes) break;
      }
      stopwatch.stop();
      if (received <= 0 || stopwatch.elapsedMilliseconds <= 0) {
        return _SpeedTestResult.failed();
      }
      final mbps = received * 8 / stopwatch.elapsedMilliseconds / 1000;
      return _SpeedTestResult(
        testing: false,
        mbps: mbps,
        checkedAt: DateTime.now(),
      );
    } catch (_) {
      stopwatch.stop();
      return _SpeedTestResult.failed();
    } finally {
      await socket?.close();
    }
  }

  Future<void> _setVerboseEdgeLogs(bool value) async {
    if (!_edgeRunning) {
      setState(() => _verboseEdgeLogs = value);
      await _saveSettings();
      return;
    }

    final reconnect = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重新连接后生效？'),
            content: const Text('详细 n2n 日志需要重新启动 edge 后生效。是否现在重新连接？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('现在重连'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted) return;
    setState(() => _verboseEdgeLogs = value);
    await _saveSettings();
    if (!reconnect) return;
    await _disconnect();
    if (!mounted) return;
    await _connect();
  }

  Future<void> _setLogDetailMode(bool compact) async {
    setState(() {
      _compactLogs = compact;
      _syncLogText();
    });
    await _setVerboseEdgeLogs(!compact);
  }

  Future<_TcpCheck> _checkTcp(String ip) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        _diagnosticPort,
        timeout: const Duration(seconds: 5),
      );
      socket.write('gon2n-tcp-ping');
      await socket.flush();
      final data = await socket.first.timeout(const Duration(seconds: 5));
      stopwatch.stop();
      final response = utf8.decode(data, allowMalformed: true);
      return _TcpCheck(
        ok: response.startsWith('gon2n-tcp-pong'),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (_) {
      stopwatch.stop();
      return const _TcpCheck(ok: false);
    } finally {
      await socket?.close();
    }
  }

  Future<_UdpCheck> _checkUdp(String ip) async {
    const probeCount = 10;
    final samples = <int>[];
    var lost = 0;
    for (var i = 0; i < probeCount; i++) {
      final sample = await _udpProbe(ip);
      if (sample == null) {
        lost++;
      } else {
        samples.add(sample);
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return _UdpCheck(
      ok: samples.isNotEmpty,
      averageMs: samples.isEmpty
          ? null
          : samples.reduce((a, b) => a + b) ~/ samples.length,
      lossPercent: (lost * 100 / probeCount).round(),
    );
  }

  Future<int?> _udpProbe(String ip) async {
    RawDatagramSocket? socket;
    try {
      final localIp = _displayAddress(_address.text);
      socket = await RawDatagramSocket.bind(
        localIp.isEmpty ? InternetAddress.anyIPv4 : InternetAddress(localIp),
        0,
      );
      final nonce = _generateToken('', 10);
      final completer = Completer<int?>();
      final stopwatch = Stopwatch()..start();
      late final StreamSubscription<RawSocketEvent> subscription;
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        final message = utf8.decode(datagram.data, allowMalformed: true);
        if (message == 'gon2n-udp-pong:$nonce' && !completer.isCompleted) {
          stopwatch.stop();
          completer.complete(stopwatch.elapsedMilliseconds);
        }
      });
      socket.send(
        utf8.encode('gon2n-udp-ping:$nonce'),
        InternetAddress(ip),
        _diagnosticPort,
      );
      final value = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      await subscription.cancel();
      return value;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  String _connectionModeFor(_OnlineMember member) {
    if (_forceRelay) return '中继';
    final cachedMode = _connectionModes[member.deviceId];
    if (cachedMode != null) return cachedMode;
    return '未知';
  }

  Future<AppExitResponse> _confirmExit() async {
    if (!mounted) return AppExitResponse.exit;
    if (_exitConfirmationOpen || _exitInProgress) {
      return AppExitResponse.cancel;
    }
    _exitConfirmationOpen = true;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('退出 GoN2N？'),
            content: const Text('退出会断开当前虚拟局域网连接并关闭网络测试服务。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('退出'),
              ),
            ],
          ),
        ) ??
        false;
    _exitConfirmationOpen = false;
    if (!confirmed) return AppExitResponse.cancel;
    _exitInProgress = true;
    try {
      await _shutdownForExit();
      return AppExitResponse.exit;
    } catch (_) {
      _exitInProgress = false;
      rethrow;
    }
  }

  Future<void> _shutdownForExit() async {
    _manualDisconnectRequested = true;
    _cancelReconnect();
    _heartbeatTimer?.cancel();
    _stopDiagnosticServer();
    await _restoreTapMetric();
    await _releaseMemberLease();
    _edge?.kill(
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigint);
    _edge = null;
  }

  Future<void> _connect({bool isAutoReconnect = false}) async {
    _ensureGeneratedFields();
    if (_memberServiceKey.text.trim().isEmpty) {
      setState(() => _advancedSettingsExpanded = true);
      _showError('请先填写成员服务密钥。');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (!isAutoReconnect) {
      _manualDisconnectRequested = false;
      _cancelReconnect();
    }
    setState(() => _connecting = true);
    try {
      if (!mounted || _edgeRunning) return;
      if (Platform.isWindows && !await _ensureTapAdapter()) {
        if (mounted) setState(() => _status = ConnectionStatus.error);
        return;
      }
      if (!await _leaseMemberAddress()) {
        if (mounted) setState(() => _status = ConnectionStatus.error);
        return;
      }
      await _saveSettings();
      final edgePath = _resolveSavedEdgePath(_edgePath.text);
      _edgePath.text = edgePath;
      final supernode = '${_server.text.trim()}:${_port.text.trim()}';
      final edgeAddress = _edgeAddress();
      _tapReadyLogged = false;
      _supernodeReadyLogged = false;
      _connectionModes.clear();
      _checkResults.clear();
      _speedTestResults.clear();
      final args = <String>[
        '-a',
        'static:$edgeAddress',
        '-l',
        supernode,
        '-E',
        if (_verboseEdgeLogs) '-v',
        if (_forceRelay) '-S1',
        if (_preferTapMetric) ...['-x', '1'],
      ];
      _appendLog('正在连接 $supernode');
      _appendLog('使用 edge：$edgePath');
      final process = await Process.start(
        edgePath,
        args,
        environment: {
          ...Platform.environment,
          'N2N_COMMUNITY': _community.text.trim(),
          'N2N_KEY': _deriveN2nKey(_key.text),
        },
        runInShell: false,
      );
      if (!mounted) {
        process.kill();
        return;
      }
      setState(() {
        _edge = process;
        _status = ConnectionStatus.connecting;
      });
      _manualDisconnectRequested = false;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleEdgeLog);
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleEdgeLog);
      unawaited(process.exitCode.then((code) {
        if (!mounted || _edge != process) return;
        final shouldReconnect = !_manualDisconnectRequested && !_exitInProgress;
        _appendLog('edge 已退出，退出码 $code');
        _heartbeatTimer?.cancel();
        _stopDiagnosticServer();
        unawaited(_restoreTapMetric());
        unawaited(_releaseMemberLease());
        setState(() {
          _edge = null;
          if (_status != ConnectionStatus.error) {
            _status = ConnectionStatus.disconnected;
          }
        });
        if (shouldReconnect) {
          _scheduleReconnect('连接意外断开');
        }
      }));
      _appendLog('edge 已启动，虚拟地址 ${_address.text.trim()}');
      unawaited(Future<void>.delayed(
        const Duration(milliseconds: 1500),
        _markEdgeConnected,
      ));
    } on ProcessException catch (error) {
      _appendLog('无法启动 edge：${error.message} (${error.executable})');
      if (mounted) setState(() => _status = ConnectionStatus.error);
      if (!isAutoReconnect) {
        _showError('无法启动 edge，请检查路径、TAP 驱动和管理员权限。');
      }
    } catch (error) {
      _appendLog('连接失败：$error');
      if (mounted) setState(() => _status = ConnectionStatus.error);
      if (!isAutoReconnect) {
        _showError('连接失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
        if (isAutoReconnect && !_edgeRunning) {
          _scheduleReconnect('自动重连失败');
        }
      }
    }
  }

  Future<void> _disconnect() async {
    final process = _edge;
    if (process == null) return;
    _manualDisconnectRequested = true;
    _cancelReconnect();
    _appendLog('正在断开连接');
    _heartbeatTimer?.cancel();
    _stopDiagnosticServer();
    await _restoreTapMetric();
    await _releaseMemberLease();
    process.kill(
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigint);
    await _waitForEdgeExit(process);
    if (!mounted) return;
    setState(() {
      _edge = null;
      _status = ConnectionStatus.disconnected;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  void _showAboutDialog() {
    final versionFuture = _readAppVersion();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关于 GoN2N'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<String>(
              future: versionFuture,
              initialData: _fallbackAppVersion,
              builder: (context, snapshot) {
                return Text('版本号：${snapshot.data ?? _fallbackAppVersion}');
              },
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _openProjectHome,
              icon: const Icon(Icons.open_in_new),
              label: const Text('langstaffe/GoN2N'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<String> _readAppVersion() async {
    if (!Platform.isWindows) return _fallbackAppVersion;
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          r"(Get-Item -LiteralPath $args[0]).VersionInfo.ProductVersion",
          Platform.resolvedExecutable,
        ],
      ).timeout(const Duration(seconds: 2));
      final version = result.stdout.toString().trim();
      if (result.exitCode == 0 && version.isNotEmpty) {
        final versionName = version.split('+').first;
        return versionName.startsWith('v') ? versionName : 'v$versionName';
      }
    } catch (_) {
      // Fall back to the release version used before build metadata is readable.
    }
    return _fallbackAppVersion;
  }

  Future<void> _openProjectHome() async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'rundll32.exe',
          ['url.dll,FileProtocolHandler', _projectHomeUrl],
          runInShell: false,
        );
      } else if (Platform.isMacOS) {
        await Process.start('open', [_projectHomeUrl], runInShell: false);
      } else {
        await Process.start('xdg-open', [_projectHomeUrl], runInShell: false);
      }
    } catch (error) {
      await Clipboard.setData(const ClipboardData(text: _projectHomeUrl));
      _showError('无法打开项目主页，链接已复制到剪切板');
    }
  }

  String _defaultEdgePath() {
    return _bundledEdgePath() ?? _fallbackEdgeName();
  }

  String _resolveSavedEdgePath(String? savedPath) {
    final bundledPath = _bundledEdgePath();
    final trimmed = savedPath?.trim() ?? '';
    if (trimmed.isEmpty) return bundledPath ?? _fallbackEdgeName();
    if (bundledPath != null &&
        _fileName(trimmed).toLowerCase() ==
            _fileName(bundledPath).toLowerCase()) {
      return bundledPath;
    }
    if (Platform.isWindows &&
        !File(trimmed).existsSync() &&
        bundledPath != null) {
      return bundledPath;
    }
    return trimmed;
  }

  String _fallbackEdgeName() {
    return Platform.isWindows ? 'edge.exe' : 'edge';
  }

  String? _bundledEdgePath() {
    if (Platform.isMacOS) {
      final executable = File(Platform.resolvedExecutable);
      final bundledEdge =
          File('${executable.parent.parent.path}/Resources/edge');
      if (bundledEdge.existsSync()) return bundledEdge.path;
    }
    if (Platform.isWindows) {
      final executable = File(Platform.resolvedExecutable);
      final bundledEdge = File('${executable.parent.path}\\edge.exe');
      if (bundledEdge.existsSync()) return bundledEdge.path;
      return _findInInstallTree((file) => _fileName(file.path) == 'edge.exe');
    }
    return null;
  }

  Future<bool> _ensureTapAdapter() async {
    if (!Platform.isWindows) return true;
    if (await _hasTapAdapter()) return true;
    if (!mounted) return false;

    final installer = _bundledTapInstallerPath();
    final install = _bundledTapInstallPath();
    final inf = _bundledTapInfPath();
    if (installer == null && (install == null || inf == null)) {
      _appendLog('未检测到 TAP-Windows 网卡，也没有找到 TAP 驱动安装文件。');
      _showError(
          '未检测到 TAP-Windows 网卡。请把 tapinstall.exe 和 OemVista.inf 放到 GoN2N_files\\tap-driver 后重新打开。');
      return false;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('需要安装 TAP 网卡'),
            content: const Text('当前系统没有检测到 TAP-Windows 网卡。是否现在自动安装？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('安装'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return false;

    _appendLog('正在安装 TAP-Windows 网卡');
    final executable = installer ?? install!;
    final args =
        installer != null ? const ['/S'] : ['install', inf!, 'tap0901'];
    final result = await Process.run(
      executable,
      args,
      runInShell: false,
    );
    if (result.stdout.toString().trim().isNotEmpty) {
      _appendLog(result.stdout.toString().trim());
    }
    if (result.stderr.toString().trim().isNotEmpty) {
      _appendLog(result.stderr.toString().trim());
    }
    final installed = result.exitCode == 0 && await _hasTapAdapter();
    if (!installed) {
      _appendLog('TAP-Windows 网卡安装失败，退出码 ${result.exitCode}');
      _showError('TAP-Windows 网卡安装失败，请确认以管理员身份运行并检查驱动文件。');
      return false;
    }
    _appendLog('TAP-Windows 网卡安装完成');
    return true;
  }

  Future<bool> _hasTapAdapter() async {
    if (!Platform.isWindows) return true;
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          r"$adapters = Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.Name -like '*TAP-Windows Adapter V9*' -or $_.Description -like '*TAP-Windows Adapter V9*' -or $_.Name -like '*TAP*' -or $_.Description -like '*TAP*' }; if ($adapters) { 'yes' }",
        ],
        runInShell: false,
      );
      return result.stdout.toString().trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String? _bundledTapInstallPath() {
    if (!Platform.isWindows) return null;
    return _findInInstallTree(
        (file) => _fileName(file.path) == 'tapinstall.exe');
  }

  String? _bundledTapInstallerPath() {
    if (!Platform.isWindows) return null;
    return _findInInstallTree((file) {
      final name = _fileName(file.path);
      return name.startsWith('tap-windows-') && name.endsWith('-win10.exe');
    });
  }

  String? _bundledTapInfPath() {
    if (!Platform.isWindows) return null;
    return _findInInstallTree((file) {
      final name = _fileName(file.path);
      return name == 'oemvista.inf' || name == 'tap0901.inf';
    });
  }

  String? _findInInstallTree(bool Function(File file) matches) {
    for (final root in _installSearchRoots()) {
      try {
        for (final entity
            in root.listSync(recursive: true, followLinks: false)) {
          if (entity is File && matches(entity)) return entity.path;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  List<Directory> _installSearchRoots() {
    final roots = <String>{};
    final executable = File(Platform.resolvedExecutable);
    roots.add(executable.parent.path);
    try {
      roots.add(executable.parent.parent.path);
    } catch (_) {
      // Ignore parent lookup failures for unusual executable paths.
    }
    return roots.map(Directory.new).where((dir) => dir.existsSync()).toList();
  }

  String _fileName(String path) {
    return path.split(RegExp(r'[\\/]')).last.toLowerCase();
  }

  Widget _buildMembersPanel(Color dividerColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '在线成员:${_members.length}',
                style: const TextStyle(fontSize: 16),
              ),
            ),
            TextButton.icon(
              onPressed:
                  _connected && !_checkingNetwork ? _runNetworkChecks : null,
              icon: const Icon(Icons.network_check_outlined),
              label: Text(_checkingNetwork ? '检查中' : '网络状态检查'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _members.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('连接后显示同社区在线成员'),
                  )
                : ListView.separated(
                    itemCount: _members.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: dividerColor,
                    ),
                    itemBuilder: (context, index) {
                      final member = _members[index];
                      final isSelf = member.deviceId == _deviceId;
                      return ListTile(
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        leading: Icon(
                          isSelf
                              ? Icons.person_pin_circle_outlined
                              : Icons.computer_outlined,
                        ),
                        title: Text(
                          isSelf ? '${member.nickname}（本机）' : member.nickname,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 95,
                              child: Text(
                                member.ip,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () => _copyMemberIp(member.ip),
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                textStyle: DefaultTextStyle.of(context)
                                    .style
                                    .copyWith(fontSize: 14),
                              ),
                              child: const Text('复制IP'),
                            ),
                          ],
                        ),
                        trailing: isSelf
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _NetworkCheckResultView(
                                    result: _checkResults[member.deviceId],
                                  ),
                                  const SizedBox(width: 4),
                                  _SpeedTestResultView(
                                    result:
                                        _speedTestResults[member.deviceId],
                                    onPressed: _connected
                                        ? () => _runSpeedTest(member)
                                        : null,
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final logTextColor =
        widget.darkMode ? const Color(0xffe5e7eb) : const Color(0xff1f2937);
    final logHintColor =
        widget.darkMode ? const Color(0xff9ca3af) : const Color(0xff6b7280);
    final dividerColor =
        widget.darkMode ? Colors.white24 : Colors.black.withValues(alpha: 0.12);
    final leftFlex = (_splitFraction * 1000).round();
    final rightFlex = 1000 - leftFlex;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('GoN2N'),
        backgroundColor: colorScheme.surface,
        actions: [
          IconButton(
            tooltip: '关于',
            onPressed: _showAboutDialog,
            icon: const Icon(Icons.error_outline),
          ),
          const SizedBox(width: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.darkMode
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined),
              const SizedBox(width: 8),
              const Text('深色模式'),
              Switch(
                value: widget.darkMode,
                onChanged: _setDarkMode,
              ),
            ],
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Chip(
              avatar: Icon(_statusIcon, color: _statusColor(context)),
              label: Text(_statusLabel),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            Flexible(
              flex: leftFlex,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('加入虚拟局域网', style: textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Expanded(
                            child: Text('填写已经部署好的 n2n 服务器信息。'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _edgeRunning ? null : _importShareConfig,
                            icon: const Icon(Icons.file_download_outlined),
                            label: const Text('导入'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _exportShareConfig,
                            icon: const Icon(Icons.ios_share_outlined),
                            label: const Text('导出'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextFormField(
                              controller: _server,
                              enabled: !_edgeRunning,
                              enableInteractiveSelection: true,
                              contextMenuBuilder: _contextMenuBuilder,
                              validator: _required,
                              decoration: InputDecoration(
                                labelText: '服务器地址',
                                hintText: 'supernode.example.com',
                                prefixIcon: const Icon(Icons.dns_outlined),
                                suffixIcon: _pasteButton(_server),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _port,
                              enabled: !_edgeRunning,
                              enableInteractiveSelection: true,
                              contextMenuBuilder: _contextMenuBuilder,
                              validator: _validatePort,
                              decoration: InputDecoration(
                                labelText: '端口',
                                suffixIcon: _pasteButton(_port),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _nickname,
                        enabled: !_edgeRunning,
                        enableInteractiveSelection: true,
                        contextMenuBuilder: _contextMenuBuilder,
                        validator: _required,
                        decoration: InputDecoration(
                          labelText: '本机昵称',
                          hintText: '显示在在线成员列表里',
                          prefixIcon: const Icon(Icons.badge_outlined),
                          suffixIcon: _pasteButton(_nickname),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: () => setState(() =>
                              _advancedSettingsExpanded =
                                  !_advancedSettingsExpanded),
                          icon: Icon(_advancedSettingsExpanded
                              ? Icons.expand_less
                              : Icons.tune),
                          label: Text(
                              _advancedSettingsExpanded ? '收起高级设置' : '展开高级设置'),
                        ),
                      ),
                      if (_advancedSettingsExpanded) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _community,
                          enabled: !_edgeRunning,
                          enableInteractiveSelection: true,
                          contextMenuBuilder: _contextMenuBuilder,
                          validator: _validateCommunity,
                          decoration: InputDecoration(
                            labelText: '社区名',
                            hintText: '所有成员必须相同',
                            prefixIcon: const Icon(Icons.groups_outlined),
                            suffixIcon: _pasteButton(_community),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _memberServiceUrl,
                          enabled: !_edgeRunning,
                          enableInteractiveSelection: true,
                          contextMenuBuilder: _contextMenuBuilder,
                          decoration: InputDecoration(
                            labelText: '成员服务地址',
                            hintText: '留空则使用 http://服务器地址:51874',
                            prefixIcon: const Icon(Icons.hub_outlined),
                            suffixIcon: _pasteButton(_memberServiceUrl),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _memberServiceKey,
                          enabled: !_edgeRunning,
                          enableInteractiveSelection: true,
                          contextMenuBuilder: _contextMenuBuilder,
                          validator: _required,
                          obscureText: _obscureMemberServiceKey,
                          decoration: InputDecoration(
                            labelText: '成员服务密钥',
                            helperText: '必须和服务器 GON2N_SHARED_SECRET 一致',
                            prefixIcon: const Icon(Icons.admin_panel_settings),
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _pasteButton(_memberServiceKey),
                                IconButton(
                                  tooltip: _obscureMemberServiceKey
                                      ? '显示成员服务密钥'
                                      : '隐藏成员服务密钥',
                                  onPressed: () => setState(() =>
                                      _obscureMemberServiceKey =
                                          !_obscureMemberServiceKey),
                                  icon: Icon(_obscureMemberServiceKey
                                      ? Icons.visibility
                                      : Icons.visibility_off),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _address,
                          enabled: !_edgeRunning,
                          enableInteractiveSelection: true,
                          contextMenuBuilder: _contextMenuBuilder,
                          validator: _validateAddress,
                          decoration: InputDecoration(
                            labelText: '虚拟 IP',
                            hintText: '10.239.180.10',
                            prefixIcon: const Icon(Icons.lan_outlined),
                            suffixIcon: _pasteButton(_address),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _key,
                          enabled: !_edgeRunning,
                          enableInteractiveSelection: true,
                          contextMenuBuilder: _contextMenuBuilder,
                          validator: _required,
                          obscureText: _obscureKey,
                          decoration: InputDecoration(
                            labelText: '共享密钥',
                            helperText: '会保存到本机配置，下次自动填写',
                            prefixIcon: const Icon(Icons.key_outlined),
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _pasteButton(_key),
                                IconButton(
                                  tooltip: _obscureKey ? '显示密钥' : '隐藏密钥',
                                  onPressed: () => setState(
                                      () => _obscureKey = !_obscureKey),
                                  icon: Icon(_obscureKey
                                      ? Icons.visibility
                                      : Icons.visibility_off),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _edgePath,
                          enabled: !_edgeRunning,
                          enableInteractiveSelection: true,
                          contextMenuBuilder: _contextMenuBuilder,
                          validator: _required,
                          decoration: InputDecoration(
                            labelText: 'edge 程序路径',
                            hintText: 'edge.exe 或 /usr/local/bin/edge',
                            prefixIcon: const Icon(Icons.folder_open_outlined),
                            suffixIcon: _pasteButton(_edgePath),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('强制通过 n2n 服务器中继'),
                        subtitle: const Text('直连受限时可开启，但会增加服务器流量'),
                        value: _forceRelay,
                        onChanged: _edgeRunning
                            ? null
                            : (value) => setState(() => _forceRelay = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('提高虚拟网卡优先级'),
                        subtitle:
                            const Text('开启后将 GoN2N 虚拟网卡跃点数设为 1，关闭后使用默认跃点数'),
                        value: _preferTapMetric,
                        onChanged: _edgeRunning
                            ? null
                            : (value) {
                                setState(() => _preferTapMetric = value);
                                if (!value) unawaited(_restoreTapMetric());
                              },
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _edgeRunning
                            ? _disconnect
                            : (_canStartConnection ? _connect : null),
                        icon: Icon(_edgeRunning
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(_connectButtonLabel),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) {
                  final width = MediaQuery.sizeOf(context).width;
                  if (width <= 0) return;
                  final delta = details.primaryDelta ?? 0;
                  setState(() {
                    _splitFraction =
                        (_splitFraction + delta / width).clamp(0.36, 0.70);
                  });
                },
                child: SizedBox(
                  width: 12,
                  child: Center(
                    child: VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: dividerColor,
                    ),
                  ),
                ),
              ),
            ),
            Flexible(
              flex: rightFlex,
              child: Container(
                color: colorScheme.surface,
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final height = constraints.maxHeight;
                    if (height < 360) {
                      return const SizedBox.shrink();
                    }
                    final minMembersFraction =
                        height <= 0 ? 0.22 : (160 / height).clamp(0.18, 0.45);
                    final minLogsFraction =
                        height <= 0 ? 0.35 : (160 / height).clamp(0.18, 0.45);
                    final maxMembersFraction = 1 - minLogsFraction;
                    final membersFraction = _rightPanelFraction.clamp(
                      minMembersFraction,
                      maxMembersFraction,
                    );
                    final membersFlex = (membersFraction * 1000).round();
                    final logsFlex = 1000 - membersFlex;
                    final logsPanel = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Text('运行日志', style: TextStyle(fontSize: 16)),
                            const SizedBox(width: 12),
                            SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: true, label: Text('简略')),
                                ButtonSegment(value: false, label: Text('详细')),
                              ],
                              selected: {_compactLogs},
                              showSelectedIcon: false,
                              style: ButtonStyle(
                                visualDensity: VisualDensity.compact,
                                minimumSize: const WidgetStatePropertyAll(
                                  Size(48, 28),
                                ),
                                textStyle: const WidgetStatePropertyAll(
                                  TextStyle(fontSize: 12),
                                ),
                                padding: const WidgetStatePropertyAll(
                                  EdgeInsets.symmetric(horizontal: 8),
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onSelectionChanged: (selection) {
                                unawaited(_setLogDetailMode(selection.first));
                              },
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed:
                                  _logText.text.isEmpty ? null : _copyLogs,
                              child: const Text('复制全部'),
                            ),
                            TextButton(
                              onPressed: _logs.isEmpty ? null : _clearLogs,
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                        Divider(color: dividerColor),
                        Expanded(
                          child: Shortcuts(
                            shortcuts: const {
                              SingleActivator(LogicalKeyboardKey.keyA,
                                      control: true):
                                  SelectAllTextIntent(
                                      SelectionChangedCause.keyboard),
                              SingleActivator(LogicalKeyboardKey.keyC,
                                  control: true): CopySelectionTextIntent.copy,
                              SingleActivator(LogicalKeyboardKey.keyA,
                                      meta: true):
                                  SelectAllTextIntent(
                                      SelectionChangedCause.keyboard),
                              SingleActivator(LogicalKeyboardKey.keyC,
                                  meta: true): CopySelectionTextIntent.copy,
                            },
                            child: TextField(
                              controller: _logText,
                              readOnly: true,
                              expands: true,
                              maxLines: null,
                              minLines: null,
                              enableInteractiveSelection: true,
                              contextMenuBuilder: _contextMenuBuilder,
                              textAlignVertical: TextAlignVertical.top,
                              style: TextStyle(
                                color: logTextColor,
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.5,
                              ),
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                hintText: '日志会显示在这里，可点击后 Ctrl+A / Ctrl+C 复制',
                                hintStyle: TextStyle(color: logHintColor),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Flexible(
                          flex: membersFlex,
                          child: _buildMembersPanel(dividerColor),
                        ),
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeRow,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onVerticalDragUpdate: (details) {
                              if (height <= 0) return;
                              final delta = details.primaryDelta ?? 0;
                              setState(() {
                                _rightPanelFraction =
                                    (_rightPanelFraction + delta / height)
                                        .clamp(
                                  minMembersFraction,
                                  maxMembersFraction,
                                );
                              });
                            },
                            child: SizedBox(
                              height: 16,
                              child: Center(
                                child: Divider(
                                  height: 1,
                                  thickness: 1,
                                  color: dividerColor,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Flexible(
                          flex: logsFlex,
                          child: logsPanel,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _secureEnvelopeVersion = 1;
final _secureSalt = utf8.encode('gon2n-member-service-v1');
final _secureKeyInfo = utf8.encode('gon2n-member-key');
final _secureBodyInfo = utf8.encode('gon2n-member-body-v1');
final _n2nKeyInfo = utf8.encode('gon2n-n2n-key');

String _deriveN2nKey(String sharedSecret) {
  final key = _hkdfSha256(
    utf8.encode(sharedSecret.trim()),
    _secureSalt,
    _n2nKeyInfo,
    32,
  );
  return _base64UrlNoPadding(key);
}

Map<String, Object?> _sealMemberPayload(
  Map<String, Object?> payload,
  String sharedSecret,
) {
  final keys = _memberBodyKeys(sharedSecret);
  final nonce = Uint8List(16);
  final random = Random.secure();
  for (var i = 0; i < nonce.length; i++) {
    nonce[i] = random.nextInt(256);
  }
  final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final ciphertext =
      _xorWithHmacStream(keys.encKey, nonce, utf8.encode(jsonEncode(payload)));
  final nonceText = _base64UrlNoPadding(nonce);
  final envelope = <String, Object?>{
    'version': _secureEnvelopeVersion,
    'nonce': nonceText,
    'timestamp': timestamp,
    'ciphertext': _base64UrlNoPadding(ciphertext),
  };
  envelope['mac'] = _base64UrlNoPadding(
    _memberEnvelopeMac(keys.macKey, envelope, ciphertext),
  );
  return envelope;
}

Map<String, dynamic> _openMemberPayload(String body, String sharedSecret) {
  final envelope = jsonDecode(body) as Map<String, dynamic>;
  final version = envelope['version'] as int? ?? 0;
  if (version != _secureEnvelopeVersion) {
    throw FormatException('成员服务返回了不支持的加密版本：$version');
  }
  final nonce = _base64UrlDecode(envelope['nonce'] as String? ?? '');
  if (nonce.length != 16) {
    throw const FormatException('成员服务返回的 nonce 无效');
  }
  final ciphertext = _base64UrlDecode(envelope['ciphertext'] as String? ?? '');
  final mac = _base64UrlDecode(envelope['mac'] as String? ?? '');
  final keys = _memberBodyKeys(sharedSecret);
  final expected = _memberEnvelopeMac(keys.macKey, envelope, ciphertext);
  if (!_constantTimeEquals(mac, expected)) {
    throw const FormatException('成员服务返回校验失败，请检查成员服务密钥是否一致');
  }
  final plain = _xorWithHmacStream(keys.encKey, nonce, ciphertext);
  return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
}

_MemberBodyKeys _memberBodyKeys(String sharedSecret) {
  final memberKey = _hkdfSha256(
    utf8.encode(sharedSecret.trim()),
    _secureSalt,
    _secureKeyInfo,
    32,
  );
  final bodyKey = _hkdfSha256(memberKey, _secureSalt, _secureBodyInfo, 64);
  return _MemberBodyKeys(
    Uint8List.fromList(bodyKey.sublist(0, 32)),
    Uint8List.fromList(bodyKey.sublist(32, 64)),
  );
}

Uint8List _memberEnvelopeMac(
  Uint8List macKey,
  Map<String, Object?> envelope,
  Uint8List ciphertext,
) {
  final message = <int>[
    ...utf8.encode('${envelope['version']}\n'),
    ...utf8.encode('${envelope['timestamp']}\n'),
    ...utf8.encode('${envelope['nonce']}\n'),
    ...ciphertext,
  ];
  return _hmacSha256(macKey, message);
}

Uint8List _xorWithHmacStream(
  Uint8List key,
  Uint8List nonce,
  List<int> input,
) {
  final output = Uint8List(input.length);
  var counter = 0;
  var offset = 0;
  while (offset < input.length) {
    final counterBytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, counter);
    final block = _hmacSha256(key, [...nonce, ...counterBytes]);
    for (var i = 0; i < block.length && offset < input.length; i++) {
      output[offset] = input[offset] ^ block[i];
      offset++;
    }
    counter++;
  }
  return output;
}

Uint8List _hkdfSha256(
  List<int> secret,
  List<int> salt,
  List<int> info,
  int length,
) {
  final prk = _hmacSha256(salt, secret);
  final output = <int>[];
  var previous = Uint8List(0);
  var counter = 1;
  while (output.length < length) {
    previous = _hmacSha256(prk, [...previous, ...info, counter]);
    output.addAll(previous);
    counter++;
  }
  return Uint8List.fromList(output.take(length).toList());
}

Uint8List _hmacSha256(List<int> key, List<int> message) {
  var normalizedKey = Uint8List.fromList(key);
  if (normalizedKey.length > 64) {
    normalizedKey = _sha256(normalizedKey);
  }
  final keyBlock = Uint8List(64)
    ..setRange(0, normalizedKey.length, normalizedKey);
  final outer = Uint8List(64);
  final inner = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    outer[i] = keyBlock[i] ^ 0x5c;
    inner[i] = keyBlock[i] ^ 0x36;
  }
  return _sha256([
    ...outer,
    ..._sha256([...inner, ...message])
  ]);
}

Uint8List _sha256(List<int> data) {
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final bytes = <int>[...data, 0x80];
  while ((bytes.length + 8) % 64 != 0) {
    bytes.add(0);
  }
  final bitLength = data.length * 8;
  final lengthBytes = Uint8List(8);
  lengthBytes.buffer.asByteData().setUint64(0, bitLength);
  bytes.addAll(lengthBytes);

  for (var offset = 0; offset < bytes.length; offset += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = _u32((bytes[j] << 24) |
          (bytes[j + 1] << 16) |
          (bytes[j + 2] << 8) |
          bytes[j + 3]);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = _u32(w[i - 16] + s0 + w[i - 7] + s1);
    }
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final temp1 = _u32(h + s1 + ch + k[i] + w[i]);
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = _u32(s0 + maj);
      h = g;
      g = f;
      f = e;
      e = _u32(d + temp1);
      d = c;
      c = b;
      b = a;
      a = _u32(temp1 + temp2);
    }
    h0 = _u32(h0 + a);
    h1 = _u32(h1 + b);
    h2 = _u32(h2 + c);
    h3 = _u32(h3 + d);
    h4 = _u32(h4 + e);
    h5 = _u32(h5 + f);
    h6 = _u32(h6 + g);
    h7 = _u32(h7 + h);
  }

  final digest = Uint8List(32);
  final writer = digest.buffer.asByteData();
  for (final entry in [
    h0,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    h7,
  ].indexed) {
    writer.setUint32(entry.$1 * 4, entry.$2);
  }
  return digest;
}

int _rotr(int value, int bits) =>
    _u32((value >> bits) | ((value << (32 - bits)) & 0xffffffff));

int _u32(int value) => value & 0xffffffff;

String _base64UrlNoPadding(List<int> value) =>
    base64Url.encode(value).replaceAll('=', '');

Uint8List _base64UrlDecode(String value) {
  final padding = (4 - value.length % 4) % 4;
  return base64Url.decode('$value${'=' * padding}');
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

class _MemberBodyKeys {
  const _MemberBodyKeys(this.encKey, this.macKey);

  final Uint8List encKey;
  final Uint8List macKey;
}

class _OnlineMember {
  const _OnlineMember({
    required this.deviceId,
    required this.nickname,
    required this.ip,
    required this.expiresAt,
  });

  final String deviceId;
  final String nickname;
  final String ip;
  final DateTime? expiresAt;

  factory _OnlineMember.fromJson(Map<String, dynamic> value) {
    return _OnlineMember(
      deviceId: value['deviceId'] as String? ?? '',
      nickname: value['nickname'] as String? ?? 'GoN2N',
      ip: value['ip'] as String? ?? '',
      expiresAt: DateTime.tryParse(value['expiresAt'] as String? ?? ''),
    );
  }
}

class _SpeedTestResultView extends StatelessWidget {
  const _SpeedTestResultView({
    required this.result,
    required this.onPressed,
  });

  final _SpeedTestResult? result;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (result?.testing == true) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (result?.mbps != null) {
      final speed = _formatSpeed(result!.mbps!);
      return SizedBox(
        width: 48,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                speed.value,
                overflow: TextOverflow.ellipsis,
                style:
                    textTheme.bodySmall?.copyWith(color: Colors.green.shade700),
              ),
              Text(
                speed.unit,
                overflow: TextOverflow.ellipsis,
                style:
                    textTheme.bodySmall?.copyWith(color: Colors.green.shade700),
              ),
            ],
          ),
        ),
      );
    }

    if (result?.failed == true) {
      return TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        child: Text(
          '测速失败',
          style: textTheme.bodySmall?.copyWith(color: Colors.red),
        ),
      );
    }

    return IconButton(
      tooltip: '测速',
      onPressed: onPressed,
      icon: const Icon(Icons.speed_outlined),
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    );
  }

  static _FormattedSpeed _formatSpeed(double mbps) {
    final mbPerSecond = mbps / 8;
    if (mbPerSecond >= 1024 * 1024) {
      return _FormattedSpeed(
        (mbPerSecond / 1024 / 1024).toStringAsFixed(2),
        'tb/s',
      );
    }
    if (mbPerSecond >= 1024) {
      return _FormattedSpeed(
        (mbPerSecond / 1024).toStringAsFixed(2),
        'gb/s',
      );
    }
    if (mbPerSecond >= 1) {
      return _FormattedSpeed(_compactNumber(mbPerSecond), 'mb/s');
    }
    return _FormattedSpeed(_compactNumber(mbPerSecond * 1024), 'kb/s');
  }

  static String _compactNumber(double value) {
    if (value >= 100) return value.toStringAsFixed(0);
    if (value >= 10) return value.toStringAsFixed(1);
    return value.toStringAsFixed(2);
  }
}

class _FormattedSpeed {
  const _FormattedSpeed(this.value, this.unit);

  final String value;
  final String unit;
}

class _NetworkCheckResultView extends StatelessWidget {
  const _NetworkCheckResultView({required this.result});

  final _NetworkCheckResult? result;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (result == null) {
      return SizedBox(
        width: 150,
        child: Text(
          '未检查',
          textAlign: TextAlign.right,
          style: textTheme.bodySmall,
        ),
      );
    }
    if (result!.testing) {
      return SizedBox(
        width: 150,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text('检查中', style: textTheme.bodySmall),
          ],
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final latency = result!.latencyMs == null ? '--' : '${result!.latencyMs}ms';
    final latencyColor = _latencyColor(result!.latencyMs);
    final tcp = result!.tcpOk ? 'TCP通' : 'TCP失败';
    final tcpColor = result!.tcpOk ? Colors.green.shade700 : Colors.red;
    final udp = result!.udpOk ? 'UDP通' : 'UDP失败';
    final udpColor = result!.udpOk ? Colors.green.shade700 : Colors.red;
    final lossPercent = result!.udpLossPercent;
    final lossText = lossPercent == null ? '' : ' 丢包$lossPercent%';
    final lossColor = _lossColor(lossPercent);
    final baseStyle = textTheme.bodySmall;
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          RichText(
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            text: TextSpan(
              style: baseStyle,
              children: [
                TextSpan(
                  text: latency,
                  style: baseStyle?.copyWith(color: latencyColor),
                ),
                const TextSpan(text: ' / '),
                TextSpan(
                  text: tcp,
                  style: baseStyle?.copyWith(color: tcpColor),
                ),
                const TextSpan(text: ' / '),
                TextSpan(
                  text: udp,
                  style: baseStyle?.copyWith(color: udpColor),
                ),
              ],
            ),
          ),
          RichText(
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            text: TextSpan(
              style: baseStyle?.copyWith(color: colorScheme.onSurfaceVariant),
              children: [
                TextSpan(text: '连接模式:${result!.mode}'),
                if (lossText.isNotEmpty)
                  TextSpan(
                    text: lossText,
                    style: baseStyle?.copyWith(color: lossColor),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _latencyColor(int? latencyMs) {
    if (latencyMs == null) return Colors.red;
    if (latencyMs < 80) return Colors.green.shade700;
    if (latencyMs <= 150) return Colors.orange.shade700;
    return Colors.red;
  }

  Color _lossColor(int? lossPercent) {
    if (lossPercent == null) return Colors.red;
    if (lossPercent == 0) return Colors.green.shade700;
    if (lossPercent <= 20) return Colors.orange.shade700;
    return Colors.red;
  }
}

class _NetworkCheckResult {
  const _NetworkCheckResult({
    required this.testing,
    this.latencyMs,
    this.udpLossPercent,
    this.tcpOk = false,
    this.udpOk = false,
    this.mode = '未知',
    this.checkedAt,
  });

  factory _NetworkCheckResult.testing() {
    return const _NetworkCheckResult(testing: true);
  }

  _NetworkCheckResult withMode(String mode) {
    return _NetworkCheckResult(
      testing: testing,
      latencyMs: latencyMs,
      udpLossPercent: udpLossPercent,
      tcpOk: tcpOk,
      udpOk: udpOk,
      mode: mode,
      checkedAt: checkedAt,
    );
  }

  final bool testing;
  final int? latencyMs;
  final int? udpLossPercent;
  final bool tcpOk;
  final bool udpOk;
  final String mode;
  final DateTime? checkedAt;
}

class _SpeedTestResult {
  const _SpeedTestResult({
    required this.testing,
    this.mbps,
    this.failed = false,
    this.checkedAt,
  });

  factory _SpeedTestResult.testing() {
    return const _SpeedTestResult(testing: true);
  }

  factory _SpeedTestResult.failed() {
    return _SpeedTestResult(
      testing: false,
      failed: true,
      checkedAt: DateTime.now(),
    );
  }

  final bool testing;
  final double? mbps;
  final bool failed;
  final DateTime? checkedAt;
}

class _TcpCheck {
  const _TcpCheck({required this.ok, this.latencyMs});

  final bool ok;
  final int? latencyMs;
}

class _UdpCheck {
  const _UdpCheck({
    required this.ok,
    this.averageMs,
    this.lossPercent,
  });

  final bool ok;
  final int? averageMs;
  final int? lossPercent;
}
