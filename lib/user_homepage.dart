import 'package:flutter/material.dart';
import 'api_helper.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'dart:async';
import 'loan_details_page.dart';
import 'loan_history_page.dart';
import 'notification_page.dart';
import 'main.dart';
import 'secrets.dart';

class UserHomepage extends StatefulWidget {
  final ValueChanged<double> onApplyTap;
  final VoidCallback onLogoutTap;
  final String userEmail;
  final String userName;

  const UserHomepage({
    super.key,
    required this.onApplyTap,
    required this.onLogoutTap,
    required this.userEmail,
    required this.userName,
  });

  @override
  State<UserHomepage> createState() => _UserHomepageState();
}

class _UserHomepageState extends State<UserHomepage> {
  String _statusTitle = "Loan Status";
  String _statusText = "Checking...";
  Color _statusColor = Colors.grey;
  bool _isLoading = true;

  double _monthlySalary = 0;
  String? _userDocId;

  late String _resolvedEmail;

  String? _currentLoanId;
  Map<String, dynamic>? _currentLoanData;
  bool _canApplyForNew = false;

  int _totalMessagesInDb = 0;
  int _seenNotificationCount = 0;

  int get _unreadCount =>
      (_totalMessagesInDb - _seenNotificationCount).clamp(0, 999);

  Timer? _notificationTimer;
  final NumberFormat _currencyFormatter = NumberFormat("#,##0");

  @override
  void initState() {
    super.initState();
    _resolvedEmail = widget.userEmail;
    _fetchUserData();
    _startNotificationPolling();
  }

  @override
  void dispose() {
    _notificationTimer?.cancel();
    super.dispose();
  }

  // --- 1. FETCH USER DATA ---
  Future<void> _fetchUserData() async {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users');

    try {
      final response = await Api.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final documents = data['documents'] as List<dynamic>?;

        if (documents != null) {
          bool userFound = false;

          for (var doc in documents) {
            final fields = doc['fields'];
            if (fields == null) continue;

            final dbEmail = fields['personal_email']?['stringValue'] ?? "";
            final dbUsername = fields['username']?['stringValue'] ?? "";

            String searchKey = widget.userEmail.toLowerCase().trim();

            if (dbEmail.toLowerCase().trim() == searchKey ||
                dbUsername.toLowerCase().trim() == searchKey) {
              String fullPath = doc['name'];
              String docId = fullPath.split('/').last;

              var salaryVal = fields['salary']?['integerValue'] ??
                  fields['salary']?['doubleValue'] ??
                  "0";
              double parsedSalary =
                  double.tryParse(salaryVal.toString()) ?? 0.0;

              var seenVal =
                  fields['seen_notification_count']?['integerValue'] ?? "0";
              int savedSeenCount = int.tryParse(seenVal) ?? 0;

              if (mounted) {
                setState(() {
                  _userDocId = docId;
                  _monthlySalary = parsedSalary;
                  _seenNotificationCount = savedSeenCount;
                  if (dbEmail.isNotEmpty) _resolvedEmail = dbEmail;
                });
              }
              userFound = true;
              break;
            }
          }

          if (userFound) {
            _fetchMyLoanStatus();
          } else {
            _fetchMyLoanStatus();
          }
        }
      }
    } catch (e) {
      print("Error fetching user data: $e");
      _fetchMyLoanStatus();
    }
  }

  // --- 2. UPDATE FIRESTORE WHEN READ ---
  Future<void> _markNotificationsAsRead() async {
    setState(() {
      _seenNotificationCount = _totalMessagesInDb;
    });

    if (_userDocId != null) {
      final url = Uri.parse(
          'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$_userDocId?updateMask.fieldPaths=seen_notification_count');

      try {
        await Api.patch(
          url,
           
          body: jsonEncode({
            "fields": {
              "seen_notification_count": {
                "integerValue": _totalMessagesInDb.toString()
              }
            }
          }),
        );
      } catch (e) {
        print("Failed to sync notification count: $e");
      }
    }
  }

  // --- 3. NOTIFICATION POLLING LOGIC ---
  void _startNotificationPolling() {
    _notificationTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_currentLoanId != null) {
        _checkNotifications();
      }
    });
  }

  Future<void> _checkNotifications() async {
    if (_currentLoanId == null) return;

    int serverCount = 0;

    try {
      String cleanId = _currentLoanId!.contains('/')
          ? _currentLoanId!.split('/').last
          : _currentLoanId!;
      final chatUrl = Uri.parse('${rtdbUrl}chats/$cleanId.json');

      final response = await Api.get(chatUrl);
      if (response.statusCode == 200 && response.body != "null") {
        final Map<String, dynamic> data = jsonDecode(response.body);
        data.forEach((key, value) {
          if (value['sender'] == 'admin') {
            serverCount++;
          }
        });
      }

      if (_statusText.toLowerCase() != 'pending review' &&
          _statusText.toLowerCase() != 'no active loan') {
        serverCount++;
      }

      if (mounted) {
        setState(() {
          _totalMessagesInDb = serverCount;
        });
      }
    } catch (e) {
      print("Notification Error: $e");
    }
  }

  Future<void> _fetchMyLoanStatus() async {
    // Only set loading if checking initially
    if (_currentLoanId == null) {
      setState(() => _isLoading = true);
    }

    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications');

    try {
      final response = await Api.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['documents'] == null) {
          _resetState();
          return;
        }

        List<dynamic> allLoans = data['documents'];
        List<Map<String, dynamic>> myLoans = [];

        for (var loan in allLoans) {
          final fields = loan['fields'];
          if (fields == null) continue;

          String? dbEmail = fields['email']?['stringValue'];
          bool isHidden = fields['is_hidden']?['booleanValue'] ?? false;

          if (!isHidden &&
              dbEmail != null &&
              dbEmail.trim().toLowerCase() ==
                  _resolvedEmail.trim().toLowerCase()) {
            String timestamp = fields['timestamp']?['timestampValue'] ?? "";
            loan['parsedTime'] = timestamp.isNotEmpty
                ? DateTime.parse(timestamp)
                : DateTime(1970);

            myLoans.add(loan);
          }
        }

        if (myLoans.isEmpty) {
          _resetState();
          return;
        }

        myLoans.sort((a, b) => b['parsedTime'].compareTo(a['parsedTime']));

        var latestLoan = myLoans.first;
        final fields = latestLoan['fields'];

        String fullPath = latestLoan['name'];
        String loanId = fullPath.split('/').last;
        String status = fields['status']?['stringValue'] ?? "pending";

        _currentLoanId = loanId;
        _currentLoanData = fields;

        _updateStatusUI(status);
        _checkNotifications();
      } else {
        _updateErrorUI("Server Error");
      }
    } catch (e) {
      _updateErrorUI("Connection Failed");
    }
  }

  void _resetState() {
    if (!mounted) return;
    setState(() {
      _statusTitle = "Loan Status";
      _statusText = "No Active Loan";
      _statusColor = Colors.grey;
      _currentLoanId = null;
      _currentLoanData = null;
      _canApplyForNew = true;
      _isLoading = false;
      _totalMessagesInDb = 0;
      _seenNotificationCount = 0;
    });
  }

  void _updateErrorUI(String error) {
    if (!mounted) return;
    setState(() {
      _statusText = error;
      _statusColor = Colors.red;
      _isLoading = false;
    });
  }

  void _updateStatusUI(String status) {
    if (!mounted) return;
    String lower = status.toLowerCase();

    String title = "Current Status";
    String text = status;
    Color color = Colors.blue;
    bool canApply = false;

    if (lower == 'pending') {
      title = "Current Status";
      text = "Pending Review";
      color = Colors.orange;
      canApply = false;
    } else if (lower == 'approved') {
      double totalLoanAmount = double.tryParse(
              _currentLoanData?['loan_amount']?['integerValue'] ?? '0') ??
          0;
      double totalPaid = 0.0;

      if (_currentLoanData != null &&
          _currentLoanData!.containsKey('payment_history') &&
          _currentLoanData!['payment_history']['arrayValue']
              .containsKey('values')) {
        List<dynamic> history =
            _currentLoanData!['payment_history']['arrayValue']['values'];
        for (var item in history) {
          String amountStr =
              item['mapValue']['fields']['amount']['integerValue'] ?? '0';
          totalPaid += double.tryParse(amountStr) ?? 0.0;
        }
      }

      bool isFullyPaid =
          totalPaid >= (totalLoanAmount - 1) && totalLoanAmount > 0;

      if (isFullyPaid) {
        title = "Last Loan Status";
        text = "Fully Paid!";
        color = Colors.green;
        canApply = true;
      } else {
        title = "Current Status";
        text = "Ongoing Application";
        color = Colors.blue;
        canApply = false;
      }
    } else if (lower == 'rejected') {
      title = "Last Loan Status";
      text = "Rejected";
      color = Colors.red;
      canApply = true;
    } else {
      text = status.toUpperCase();
    }

    setState(() {
      _statusTitle = title;
      _statusText = text;
      _statusColor = color;
      _canApplyForNew = canApply;
      _isLoading = false;
    });
  }

  void _navigateToDetails() async {
    if (_currentLoanId == null || _currentLoanData == null) return;
    setState(() => _isLoading = true);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LoanDetailsPage(
          loanData: _currentLoanData!,
          loanId: _currentLoanId!,
          onUpdate: _fetchMyLoanStatus,
          currentUserType: 'user',
        ),
      ),
    );
    _fetchMyLoanStatus();
  }

  @override
  Widget build(BuildContext context) {
    // --- ANIMATION SWITCHER ---
    // This handles the Fade In between Loading (True) and Main Content (False)
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250), // Fade speed
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: _isLoading
          ? Scaffold(
              key: const ValueKey('loading'),
              body: Container(
                decoration: kAppBackground,
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            )
          : Scaffold(
              key: const ValueKey('content'),
              extendBodyBehindAppBar: true,
              backgroundColor: Colors.grey[50],
              body: Container(
                decoration: kAppBackground,
                child: SafeArea(
                  child: _buildMainBody(),
                ),
              ),
            ),
    );
  }

  // Extracted the main body construction to keep the build method clean
  Widget _buildMainBody() {
    double monthlyPayment = _monthlySalary;
    double yearlyPayment = monthlyPayment * 12;
    String displayName = widget.userName.isEmpty ? "User" : widget.userName;

    // 1. Header
    Widget welcomeHeader = Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 20),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            "Welcome, $displayName!",
            style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.black87),
            textAlign: TextAlign.center,
          ),
          Positioned(
            right: 0,
            top: 0,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.notifications_none,
                        size: 28, color: Colors.black87),
                    onPressed: () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (c) => NotificationPage(
                                    unreadCount: _unreadCount,
                                    onClear: () {
                                      _markNotificationsAsRead();
                                    },
                                    loanData: _currentLoanData,
                                    loanId: _currentLoanId,
                                    onRefresh: _fetchMyLoanStatus,
                                  )));
                    },
                  ),
                  if (_unreadCount > 0)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                              color: Colors.red, shape: BoxShape.circle),
                          constraints:
                              const BoxConstraints(minWidth: 18, minHeight: 18),
                          child: Text(
                            '$_unreadCount',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                ],
              ),
            ),
          )
        ],
      ),
    );

    // 2. Status Card
    Widget statusCard = SizedBox(
        height: 200, width: double.infinity, child: _buildStatusCard());

    // 3. History Button
    Widget historyButton = SizedBox(
      height: 50,
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) =>
                    LoanHistoryPage(userEmail: _resolvedEmail)),
          );
          _fetchMyLoanStatus();
        },
        icon: const Icon(Icons.history, color: Colors.black54),
        label: const Text("View Application History",
            style: TextStyle(color: Colors.black54, fontSize: 16)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.black12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.white.withOpacity(0.5),
        ),
      ),
    );

    // 4. Logout
    Widget logoutButton = SizedBox(
      height: 50,
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: widget.onLogoutTap,
        icon: const Icon(Icons.logout, color: Colors.redAccent, size: 20),
        label: const Text("Log Out",
            style: TextStyle(color: Colors.redAccent, fontSize: 16)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.redAccent),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.white.withOpacity(0.5),
        ),
      ),
    );

    // 5. Dynamic Components Logic
    Widget rightColumnContent;
    Widget leftColumnBottom;

    if (_canApplyForNew) {
      // MODE A: APPLY (HERO)
      rightColumnContent = SizedBox(
        height: 424,
        child: _buildHeroApplyCard(monthlyPayment),
      );
      leftColumnBottom = SizedBox(
        height: 124,
        child: _buildCompactSalaryCard(monthlyPayment),
      );
    } else {
      // MODE B: VIEW / ONGOING
      rightColumnContent = SizedBox(
        height: 424,
        width: double.infinity,
        child: _buildPaymentCard(monthlyPayment, yearlyPayment),
      );
      leftColumnBottom = SizedBox(
        height: 100,
        width: double.infinity,
        child: PrimaryHoverButton(
          onTap: _navigateToDetails,
          label: "View Active Loan Details",
          color: Colors.blueGrey,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        bool isSmallScreen =
            constraints.maxWidth < 725 || constraints.maxHeight < 485;

        if (isSmallScreen) {
          // MOBILE LAYOUT
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                welcomeHeader,
                if (_canApplyForNew) ...[
                  SizedBox(
                      height: 180,
                      width: double.infinity,
                      child: _buildHeroApplyCard(monthlyPayment,
                          isMobile: true)),
                  const SizedBox(height: 24),
                ],
                historyButton,
                const SizedBox(height: 16),
                statusCard,
                const SizedBox(height: 24),
                if (!_canApplyForNew) ...[
                  leftColumnBottom,
                  const SizedBox(height: 24),
                ],
                (!_canApplyForNew
                    ? rightColumnContent
                    : _buildCompactSalaryCard(monthlyPayment)),
                const SizedBox(height: 32),
                logoutButton,
              ],
            ),
          );
        } else {
          // DESKTOP LAYOUT
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                welcomeHeader,
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            historyButton,
                            const SizedBox(height: 16),
                            Expanded(flex: 2, child: statusCard),
                            const SizedBox(height: 16),
                            leftColumnBottom,
                            const SizedBox(height: 24),
                            logoutButton,
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(flex: 6, child: rightColumnContent),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
      },
    );
  }

  // --- COMPONENT: HERO APPLY CARD ---
  Widget _buildHeroApplyCard(double monthlyPayment, {bool isMobile = false}) {
    double yearlySalary = monthlyPayment * 12;

    return Card(
      elevation: 8,
      shadowColor: Colors.blue.withOpacity(0.4),
      color: Colors.blue[600],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Stack(
        children: [
          // Decorative background circles
          Positioned(
            right: -50,
            bottom: -50,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.1),
              ),
            ),
          ),
          Positioned(
            left: -30,
            top: -30,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.1),
              ),
            ),
          ),

          // Content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.add_card,
                      size: isMobile ? 32 : 48, color: Colors.blue[700]),
                ),
                const SizedBox(height: 24),
                const Text(
                  "Apply for a Loan",
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1),
                ),
                const SizedBox(height: 8),
                Text(
                  "Get up to ${_currencyFormatter.format(yearlySalary)} THB",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.blue[50],
                  ),
                ),
                const SizedBox(height: 30),

                // --- CUSTOM HOVER BUTTON ---
                _StartApplicationButton(
                  onTap: () => widget.onApplyTap(monthlyPayment),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- COMPACT SALARY CARD ---
  Widget _buildCompactSalaryCard(double monthly) {
    double yearly = monthly * 12;
    return Card(
      elevation: 2,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Monthly Salary",
                    style: TextStyle(
                        color: Colors.grey,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                Text(
                  '${_currencyFormatter.format(monthly)} THB',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.black87),
                ),
              ],
            ),
            Divider(height: 1, color: Colors.grey.withOpacity(0.2)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Yearly Salary",
                    style: TextStyle(
                        color: Colors.grey,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                Text(
                  '${_currencyFormatter.format(yearly)} THB',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.black87),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      elevation: 5,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_statusTitle,
                    style: const TextStyle(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 8),
                Text(_statusText,
                    style: TextStyle(
                        fontSize: 32,
                        color: _statusColor,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: IconButton(
                icon: const Icon(Icons.refresh, color: Colors.grey),
                onPressed: _fetchMyLoanStatus),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentCard(double monthly, double yearly) {
    return Card(
      elevation: 5,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          Expanded(
              child: Center(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                const Text('Monthly Salary',
                    style: TextStyle(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 10),
                Text('${_currencyFormatter.format(monthly)} THB',
                    style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87))
              ]))),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Divider(color: Colors.grey[200])),
          Expanded(
              child: Center(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                const Text('Yearly Salary',
                    style: TextStyle(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 10),
                Text('${_currencyFormatter.format(yearly)} THB',
                    style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87))
              ]))),
        ],
      ),
    );
  }
}

// --- NEW COMPONENT: HOVERABLE START APPLICATION BUTTON ---
class _StartApplicationButton extends StatefulWidget {
  final VoidCallback onTap;
  const _StartApplicationButton({required this.onTap});

  @override
  State<_StartApplicationButton> createState() =>
      _StartApplicationButtonState();
}

class _StartApplicationButtonState extends State<_StartApplicationButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(30),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              // Change color on hover (White -> Light Grey)
              color: _isHovered ? Colors.grey[300] : Colors.white,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Text(
              "Start Application",
              style: TextStyle(
                  color: Colors.blue[800],
                  fontWeight: FontWeight.bold,
                  fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}

// --- EXISTING COMPONENT: PRIMARY HOVER BUTTON (Used for "View Details") ---
class PrimaryHoverButton extends StatefulWidget {
  final VoidCallback onTap;
  final String label;
  final MaterialColor color;

  const PrimaryHoverButton(
      {super.key,
      required this.onTap,
      required this.label,
      required this.color});

  @override
  State<PrimaryHoverButton> createState() => _PrimaryHoverButtonState();
}

class _PrimaryHoverButtonState extends State<PrimaryHoverButton> {
  bool _isHovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: _isHovered ? widget.color[800] : widget.color,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: widget.color.withOpacity(0.3),
                blurRadius: 10,
                offset: const Offset(0, 5))
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: widget.onTap,
            child: Center(
              child: Text(widget.label,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}