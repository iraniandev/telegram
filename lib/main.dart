import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TelegramService.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EzyTel Pro',
      debugShowCheckedModeBanner: false,
      theme: _darkTheme(),
      home: const HomeScreen(),
    );
  }

  ThemeData _darkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: const Color(0xFF8A2BE2),
      scaffoldBackgroundColor: const Color(0xFF0A0A0A),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1A1A1A),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
      listTileTheme: const ListTileThemeData(
        selectedColor: Color(0xFF8A2BE2),
        selectedTileColor: Color(0xFF2A1A4A),
      ),
    );
  }
}

// ========================== سرویس تلگرام ==========================
class TelegramService {
  static late Directory cacheDir;
  static const List<String> googleDomains = [
    'www.google.com',
    'safebrowsing.google.com',
    'images.google.com',
    'maps.google.com',
    'news.google.com',
    'scholar.google.com',
    'meet.google.com',
    'mail.google.com',
    'drive.google.com',
  ];
  static final Random _random = Random();
  static late SharedPreferences _prefs;

  static Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    cacheDir = Directory('${appDir.path}/telegram_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    _prefs = await SharedPreferences.getInstance();
  }

  static String _pickRandomDomain() => googleDomains[_random.nextInt(googleDomains.length)];

  static Future<String> _curlGet(String params) async {
    final domain = _pickRandomDomain();
    String url = 'https://$domain/s/$params';
    url += url.contains('?') ? '&' : '?';
    url += '_x_tr_sl=el&_x_tr_tl=en&_x_tr_hl=en&_x_tr_pto=wapp';
    try {
      final response = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
      });
      if (response.statusCode == 200) return response.body;
      return 'ERROR: ${response.statusCode}';
    } catch (e) {
      return 'ERROR: $e';
    }
  }

  static Future<String> _curlAuto(String params) async {
    String res = await _curlGet(params);
    for (int i = 1; i <= 2; i++) {
      if (res.startsWith('ERROR') && res.contains('timeout')) {
        res = await _curlGet(params);
      } else break;
    }
    return res;
  }

  static Future<bool> _downloadImage(String url, String filename) async {
    final file = File('${cacheDir.path}/$filename');
    if (await file.exists()) return true;
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return true;
      }
    } catch (_) {}
    return false;
  }

  static Future<Map<String, dynamic>> fetchChannelInfo(String chid) async {
    final html = await _curlAuto(chid);
    if (html.startsWith('ERROR') || !html.contains('<meta property="og:title"')) {
      throw Exception('Channel not accessible');
    }
    final document = html_parser.parse(html);
    final result = <String, dynamic>{};
    final title = document.querySelector('meta[property="og:title"]');
    result['name'] = title?.attributes['content'] ?? chid;
    final ogImage = document.querySelector('meta[property="og:image"]');
    if (ogImage != null) {
      final imgUrl = ogImage.attributes['content'];
      if (imgUrl != null && imgUrl.isNotEmpty) {
        final hash = _md5(imgUrl);
        final filename = '$hash.jpg';
        if (await _downloadImage(imgUrl, filename)) {
          result['avatar'] = '${cacheDir.path}/$filename';
        }
      }
    }
    final lastPost = document.querySelector('.tgme_widget_message');
    if (lastPost != null) {
      final postAttr = lastPost.attributes['data-post'];
      if (postAttr != null && postAttr.contains('/')) {
        final lastCode = postAttr.split('/').last;
        final textElem = lastPost.querySelector('.tgme_widget_message_text');
        result['desc'] = textElem?.text.trim() ?? '📎 Media';
        final timeElem = lastPost.querySelector('time');
        if (timeElem != null && timeElem.attributes['datetime'] != null) {
          final dt = DateTime.parse(timeElem.attributes['datetime']!);
          result['date'] = dt.millisecondsSinceEpoch ~/ 1000;
          result['datestr'] = _toPersianDate(dt);
        }
        final lastReadStr = _prefs.getString('lastread_$chid') ?? '0';
        final lastRead = int.tryParse(lastReadStr) ?? 0;
        final lastCodeInt = int.tryParse(lastCode) ?? 0;
        if (lastCodeInt > lastRead) {
          final diff = lastCodeInt - lastRead;
          result['newmsg'] = diff > 99 ? '+99' : '+$diff';
        } else {
          result['newmsg'] = '';
        }
        result['lastPostId'] = lastCode;
      }
    }
    final cacheFile = File('${cacheDir.path}/${chid}_info.json');
    await cacheFile.writeAsString(jsonEncode(result));
    return result;
  }

  static Future<String> fetchMessagesHtml(String chid, {String? before}) async {
    String params = chid;
    if (before != null && before.isNotEmpty && before != '0') {
      params = '$chid?before=$before';
    }
    String html = await _curlAuto(params);
    if (html.startsWith('ERROR')) throw Exception('Failed to load messages');

    // جایگزینی تصاویر
    final imgRegex = RegExp(r'<img\s+[^>]*src="https://([^"]+)"');
    for (final match in imgRegex.allMatches(html)) {
      final fullTag = match.group(0)!;
      final imgUrl = match.group(1)!;
      final hash = _md5(imgUrl);
      final filename = '$hash.jpg';
      await _downloadImage('https://$imgUrl', filename);
      final localPath = '${cacheDir.path}/$filename';
      html = html.replaceFirst(fullTag, fullTag.replaceFirst('https://$imgUrl', localPath));
    }

    // تبدیل تاریخ
    final timeRegex = RegExp(r'<time datetime="([^"]+)"');
    for (final match in timeRegex.allMatches(html)) {
      final dtStr = match.group(1)!;
      final dt = DateTime.parse(dtStr);
      final persianDate = _toPersianDate(dt);
      html = html.replaceFirst(
        RegExp(r'<time[^>]*>.*?</time>', dotAll: true),
        '<span style="color:#888;font-size:12px;">$persianDate</span>',
      );
    }

    final headerEnd = html.indexOf('</header>');
    final mainEnd = html.indexOf('</main>');
    if (headerEnd == -1 || mainEnd == -1) throw Exception('Invalid structure');
    String content = html.substring(headerEnd + 9, mainEnd + 7);

    final moreMatch = RegExp(r'data-before="([^"]+)"').firstMatch(content);
    if (moreMatch != null) {
      final beforeValue = moreMatch.group(1)!;
      content = content.replaceAllMapped(
        RegExp(r'<a[^>]*messages_more_wrap[^>]*>.*?</a>', dotAll: true),
        (_) => '<button onclick="load_more($beforeValue,\'$chid\',this)" style="background:#8A2BE2;color:white;padding:10px;border:none;border-radius:20px;margin:10px auto;display:block;">Load More</button>',
      );
    }
    content = content.replaceAll(RegExp(r'<a[^>]*data-after[^>]*>.*?</a>', dotAll: true), '');

    if (before == null || before.isEmpty || before == '0') {
      final docFull = html_parser.parse(html);
      final channelName = docFull.querySelector('.tgme_header_title')?.text.trim() ?? chid;
      final subscribers = docFull.querySelector('.tgme_header_counter')?.text.trim() ?? '';
      String avatarPath = '';
      final cacheFile = File('${cacheDir.path}/${chid}_info.json');
      if (await cacheFile.exists()) {
        final cached = jsonDecode(await cacheFile.readAsString());
        avatarPath = cached['avatar'] ?? '';
      }
      final header = '''
        <div style="background:#1A1A1A; padding:15px; display:flex; gap:15px; align-items:center; border-bottom:1px solid #333;">
          <img src="$avatarPath" width="50" height="50" style="border-radius:25px;">
          <div>
            <strong style="font-size:18px;">$channelName</strong>
            <div style="font-size:12px; color:#888;">$subscribers</div>
          </div>
        </div>
      ''';
      content = header + content;

      final lastPost = docFull.querySelector('.tgme_widget_message');
      if (lastPost != null) {
        final postAttr = lastPost.attributes['data-post'];
        if (postAttr != null && postAttr.contains('/')) {
          final lastId = postAttr.split('/').last;
          await _prefs.setString('lastread_$chid', lastId);
        }
      }
    }
    return content;
  }

  static Future<List<String>> getSavedChannels() async {
    return _prefs.getStringList('channels') ?? [];
  }

  static Future<void> addChannel(String chid) async {
    final list = await getSavedChannels();
    if (!list.contains(chid)) {
      list.add(chid);
      await _prefs.setStringList('channels', list);
    }
  }

  static Future<void> removeChannel(String chid) async {
    final list = await getSavedChannels();
    list.remove(chid);
    await _prefs.setStringList('channels', list);
  }

  static String _md5(String input) => base64Url.encode(utf8.encode(input)).substring(0, 16);

  static String _toPersianDate(DateTime dt) {
    final (jy, jm, jd) = _gregorianToJalali(dt.year, dt.month, dt.day);
    final time = DateFormat.Hm().format(dt);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final inputDate = DateTime(dt.year, dt.month, dt.day);
    if (inputDate == today) return 'Today $time';
    if (inputDate == yesterday) return 'Yesterday $time';
    return '$jy-${jm.toString().padLeft(2, '0')}-${jd.toString().padLeft(2, '0')} $time';
  }

  static (int year, int month, int day) _gregorianToJalali(int gy, int gm, int gd) {
    const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    var gy2 = gm > 2 ? gy + 1 : gy;
    var days = 355666 + (365 * gy) + ((gy2 + 3) ~/ 4) - ((gy2 + 99) ~/ 100) + ((gy2 + 399) ~/ 400) + gd + gdm[gm - 1];
    var jy = -1595 + (33 * (days ~/ 12053));
    days %= 12053;
    jy += 4 * (days ~/ 1461);
    days %= 1461;
    if (days > 365) {
      jy += (days - 1) ~/ 365;
      days = (days - 1) % 365;
    }
    final jm = days < 186 ? 1 + (days ~/ 31) : 7 + ((days - 186) ~/ 30);
    final jd = 1 + (days < 186 ? days % 31 : (days - 186) % 30);
    return (jy, jm, jd);
  }
}

// ========================== مدل کانال ==========================
class ChannelItem {
  final String id;
  String name;
  String? avatarPath;
  String? lastMessage;
  String? lastDate;
  int unreadCount;

  ChannelItem({
    required this.id,
    required this.name,
    this.avatarPath,
    this.lastMessage,
    this.lastDate,
    this.unreadCount = 0,
  });
}

// ========================== صفحه اصلی ==========================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ChannelItem> _channels = [];
  ChannelItem? _selectedChannel;
  String _messagesHtml = '';
  bool _isLoading = true;
  bool _isLoadingMessages = false;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadChannels();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _loadChannels() async {
    final savedIds = await TelegramService.getSavedChannels();
    final List<ChannelItem> temp = [];
    for (final id in savedIds) {
      try {
        final info = await TelegramService.fetchChannelInfo(id);
        temp.add(ChannelItem(
          id: id,
          name: info['name'] ?? id,
          avatarPath: info['avatar'],
          lastMessage: info['desc'],
          lastDate: info['datestr'],
          unreadCount: info['newmsg'] is String && info['newmsg'].toString().startsWith('+')
              ? int.tryParse(info['newmsg'].toString().substring(1)) ?? 0
              : 0,
        ));
        setState(() {});
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        temp.add(ChannelItem(id: id, name: id, lastMessage: 'Error loading'));
      }
    }
    temp.sort((a, b) => (b.lastDate ?? '').compareTo(a.lastDate ?? ''));
    setState(() {
      _channels = temp;
      _isLoading = false;
    });
    if (_channels.isNotEmpty) await _selectChannel(_channels.first);
  }

  Future<void> _addChannel(String rawId) async {
    final cleanId = rawId.trim()
        .replaceAll('@', '')
        .replaceAll('https://t.me/', '')
        .replaceAll('t.me/', '')
        .replaceAll('/s/', '');
    if (cleanId.isEmpty) return;

    if (_channels.any((c) => c.id == cleanId)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Channel already added')));
      return;
    }

    setState(() => _isLoading = true);
    await TelegramService.addChannel(cleanId);
    await _loadChannels();
  }

  Future<void> _removeChannel(String id) async {
    await TelegramService.removeChannel(id);
    if (_selectedChannel?.id == id) {
      setState(() => _selectedChannel = null);
    }
    await _loadChannels();
  }

  Future<void> _selectChannel(ChannelItem channel) async {
    if (_selectedChannel?.id == channel.id) return;
    setState(() {
      _selectedChannel = channel;
      _messagesHtml = '';
      _isLoadingMessages = true;
    });
    try {
      final html = await TelegramService.fetchMessagesHtml(channel.id);
      setState(() {
        _messagesHtml = html;
        _isLoadingMessages = false;
      });
    } catch (e) {
      setState(() => _isLoadingMessages = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _onScroll() {
    // در صورت نیاز بارگذاری بیشتر – فعلاً ساده
  }

  void _showSearchDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Channel', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1E1E1E),
        content: TextField(
          controller: _searchController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '@username or t.me/...',
            hintStyle: TextStyle(color: Colors.grey),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              _addChannel(_searchController.text);
              Navigator.pop(context);
              _searchController.clear();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8A2BE2)),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _channels.where((c) =>
        c.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
        c.id.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('EzyTel Pro'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _showSearchDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // نوار کناری کانال‌ها
                Container(
                  width: 300,
                  color: const Color(0xFF121212),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: TextField(
                          onChanged: (v) => setState(() => _searchQuery = v),
                          decoration: const InputDecoration(
                            hintText: 'Filter channels...',
                            prefixIcon: Icon(Icons.filter_list),
                            filled: true,
                            fillColor: Color(0xFF2A2A2A),
                            border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(30))),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (ctx, i) {
                            final ch = filtered[i];
                            return Dismissible(
                              key: Key(ch.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                color: Colors.red,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              onDismissed: (_) => _removeChannel(ch.id),
                              child: ListTile(
                                leading: ClipOval(
                                  child: ch.avatarPath != null && File(ch.avatarPath!).existsSync()
                                      ? Image.file(File(ch.avatarPath!), width: 48, height: 48, fit: BoxFit.cover)
                                      : Container(
                                          width: 48,
                                          height: 48,
                                          color: Colors.purple,
                                          child: Center(child: Text(ch.name[0].toUpperCase(), style: const TextStyle(fontSize: 20))),
                                        ),
                                ),
                                title: Text(ch.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Text(ch.lastMessage ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                                trailing: ch.unreadCount > 0
                                    ? Container(
                                        width: 28,
                                        height: 28,
                                        decoration: const BoxDecoration(color: Color(0xFF8A2BE2), shape: BoxShape.circle),
                                        child: Center(child: Text('${ch.unreadCount}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                                      )
                                    : null,
                                selected: _selectedChannel?.id == ch.id,
                                selectedTileColor: const Color(0xFF2A1A4A),
                                onTap: () => _selectChannel(ch),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                // بخش پیام‌ها
                Expanded(
                  child: _selectedChannel == null
                      ? const Center(child: Text('Select a channel', style: TextStyle(color: Colors.grey)))
                      : _isLoadingMessages
                          ? const Center(child: CircularProgressIndicator())
                          : SingleChildScrollView(
                              controller: _scrollController,
                              reverse: true,
                              padding: const EdgeInsets.all(12),
                              child: HtmlWidget(html: _messagesHtml),
                            ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showSearchDialog,
        backgroundColor: const Color(0xFF8A2BE2),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ========================== ویجت ساده HTML ==========================
class HtmlWidget extends StatelessWidget {
  final String html;
  const HtmlWidget({super.key, required this.html});

  @override
  Widget build(BuildContext context) {
    final clean = html.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
    return Text(clean, style: const TextStyle(color: Colors.white, height: 1.5));
  }
}
