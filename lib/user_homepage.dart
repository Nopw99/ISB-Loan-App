import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart'; 
import 'dart:async'; 
// Removed SharedPreferences import
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
  String? _userDocId; // <--- To store the Firestore Document ID

  String? _currentLoanId; 
  Map<String, dynamic>? _currentLoanData;
  bool _canApplyForNew = false; 

  int _totalMessagesInDb = 0; 
  int _seenNotificationCount = 0; 
  
  int get _unreadCount => (_totalMessagesInDb - _seenNotificationCount).clamp(0, 999);

  Timer? _notificationTimer;
  final NumberFormat _currencyFormatter = NumberFormat("#,##0");

  @override
  void initState() {
    super.initState();
    _fetchMyLoanStatus();
    _fetchUserData(); // <--- Fetches Salary AND Notification Count
    _startNotificationPolling(); 
  }

  @override
  void dispose() {
    _notificationTimer?.cancel();
    super.dispose();
  }

  // --- 1. FETCH USER DATA (Salary + Notification State) ---
  Future<void> _fetchUserData() async {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users');

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final documents = data['documents'] as List<dynamic>?;

        if (documents != null) {
          for (var doc in documents) {
            final fields = doc['fields'];
            if (fields == null) continue;

            final dbEmail = fields['personal_email']?['stringValue'] ?? "";
            
            if (dbEmail.toLowerCase().trim() == widget.userEmail.toLowerCase().trim()) {
              // 1. Get Doc ID (for future updates)
              String fullPath = doc['name']; 
              String docId = fullPath.split('/').last;

              // 2. Get Salary
              var salaryVal = fields['salary']?['integerValue'] ?? fields['salary']?['doubleValue'] ?? "0";
              double parsedSalary = double.tryParse(salaryVal.toString()) ?? 0.0;

              // 3. Get Seen Count (Saved in DB)
              var seenVal = fields['seen_notification_count']?['integerValue'] ?? "0";
              int savedSeenCount = int.tryParse(seenVal) ?? 0;

              if (mounted) {
                setState(() {
                  _userDocId = docId;
                  _monthlySalary = parsedSalary;
                  _seenNotificationCount = savedSeenCount;
                });
              }
              break; 
            }
          }
        }
      }
    } catch (e) {
      print("Error fetching user data: $e");
    }
  }

  // --- 2. UPDATE FIRESTORE WHEN READ ---
  Future<void> _markNotificationsAsRead() async {
    // 1. Update UI Immediately (Optimistic)
    setState(() {
      _seenNotificationCount = _totalMessagesInDb;
    });

    // 2. If we found the user doc, update Firestore
    if (_userDocId != null) {
      final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$_userDocId?updateMask.fieldPaths=seen_notification_count'
      );

      try {
        await http.patch(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            "fields": {
              "seen_notification_count": {"integerValue": _totalMessagesInDb.toString()}
            }
          }),
        );
        print("Notification count synced to cloud.");
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
      String cleanId = _currentLoanId!.contains('/') ? _currentLoanId!.split('/').last : _currentLoanId!;
      final chatUrl = Uri.parse('${rtdbUrl}chats/$cleanId.json');
      
      final response = await http.get(chatUrl);
      if (response.statusCode == 200 && response.body != "null") {
        final Map<String, dynamic> data = jsonDecode(response.body);
        data.forEach((key, value) {
          if (value['sender'] == 'admin') {
             serverCount++; 
          }
        });
      }
      
      if (_statusText.toLowerCase() != 'pending review' && _statusText.toLowerCase() != 'no active loan') {
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
    setState(() => _isLoading = true);
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications');

    try {
      final response = await http.get(url);

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
          
          if (!isHidden && dbEmail != null && 
              dbEmail.trim().toLowerCase() == widget.userEmail.trim().toLowerCase()) {
            
            String timestamp = fields['timestamp']?['timestampValue'] ?? "";
            loan['parsedTime'] = timestamp.isNotEmpty ? DateTime.parse(timestamp) : DateTime(1970);
            
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
      title = "Last Loan Status";
      text = "Approved!";
      color = Colors.green;
      canApply = true; 
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
    double monthlyPayment = _monthlySalary; 
    double yearlyPayment = monthlyPayment * 12;
    String displayName = widget.userName.isEmpty ? "User" : widget.userName;

    Widget welcomeHeader = Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 20),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            "Welcome, $displayName!", 
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.black87),
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
                    icon: const Icon(Icons.notifications_none, size: 28, color: Colors.black87),
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (c) => NotificationPage(
                        unreadCount: _unreadCount, 
                        onClear: () {
                          // --- UPDATED: CALL THE CLOUD SAVE FUNCTION ---
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
                          decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                          constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                          child: Text(
                            '$_unreadCount', 
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
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

    Widget statusSection = SizedBox(height: 200, width: double.infinity, child: _buildStatusCard());
    
    Widget actionButton = SizedBox(
      height: 100, 
      width: double.infinity,
      child: _canApplyForNew 
        ? PrimaryHoverButton(
            onTap: () => widget.onApplyTap(monthlyPayment), 
            label: "Apply for Loan", 
            color: Colors.blue
          )
        : PrimaryHoverButton(
            onTap: _navigateToDetails, 
            label: "View Loan Details", 
            color: Colors.blueGrey
          ),
    );
    
    Widget historyButton = SizedBox(
      height: 50,
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => LoanHistoryPage(userEmail: widget.userEmail)),
          );
          _fetchMyLoanStatus();
        },
        icon: const Icon(Icons.history, color: Colors.black54),
        label: const Text("View Application History", style: TextStyle(color: Colors.black54, fontSize: 16)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.black12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.white.withOpacity(0.5),
        ),
      ),
    );

    Widget paymentSection = SizedBox(height: 424, width: double.infinity, child: _buildPaymentCard(monthlyPayment, yearlyPayment));
    
    Widget logoutButton = SizedBox(
      height: 50, 
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: widget.onLogoutTap,
        icon: const Icon(Icons.logout, color: Colors.redAccent, size: 20),
        label: const Text("Log Out", style: TextStyle(color: Colors.redAccent, fontSize: 16)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.redAccent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.white.withOpacity(0.5),
        ),
      ),
    );

    return Scaffold(
      extendBodyBehindAppBar: true, 
      backgroundColor: Colors.grey[50], 
      body: Container( 
        decoration: kAppBackground,
        child: SafeArea( 
          child: LayoutBuilder(
            builder: (context, constraints) {
              bool isSmallScreen = constraints.maxWidth < 725 || constraints.maxHeight < 485;

              if (isSmallScreen) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      welcomeHeader,
                      historyButton, 
                      const SizedBox(height: 16),
                      statusSection,
                      const SizedBox(height: 24),
                      actionButton,
                      const SizedBox(height: 24),
                      paymentSection,
                      const SizedBox(height: 32),
                      logoutButton,
                    ],
                  ),
                );
              } else {
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
                                  Expanded(flex: 2, child: statusSection),
                                  const SizedBox(height: 16),
                                  Expanded(flex: 1, child: actionButton),
                                  const SizedBox(height: 24),
                                  logoutButton,
                                ],
                              ),
                            ),
                            const SizedBox(width: 24),
                            Expanded(flex: 6, child: paymentSection),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
            },
          ),
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
            child: _isLoading 
            ? const CircularProgressIndicator()
            : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_statusTitle, style: const TextStyle(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 8),
                Text(_statusText, style: TextStyle(fontSize: 32, color: _statusColor, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Positioned(
            top: 10, right: 10,
            child: IconButton(icon: const Icon(Icons.refresh, color: Colors.grey), onPressed: _fetchMyLoanStatus),
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
          Expanded(child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('Monthly Salary', style: TextStyle(fontSize: 16, color: Colors.grey)), 
            const SizedBox(height: 10), 
            Text('${_currencyFormatter.format(monthly)} THB', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.black87))
          ]))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Divider(color: Colors.grey[200])),
          Expanded(child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('Yearly Salary', style: TextStyle(fontSize: 16, color: Colors.grey)), 
            const SizedBox(height: 10), 
            Text('${_currencyFormatter.format(yearly)} THB', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.black87))
          ]))),
        ],
      ),
    );
  }
}

class PrimaryHoverButton extends StatefulWidget {
  final VoidCallback onTap;
  final String label;
  final MaterialColor color;

  const PrimaryHoverButton({super.key, required this.onTap, required this.label, required this.color});

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
          boxShadow: [BoxShadow(color: widget.color.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: widget.onTap,
            child: Center(
              child: Text(widget.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}