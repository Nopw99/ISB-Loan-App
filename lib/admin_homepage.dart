import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api_helper.dart';
import 'dart:convert';
import 'dart:async';
import 'package:intl/intl.dart';
import 'loan_details_page.dart';
import 'secrets.dart'; // Make sure 'payday' is defined here as an int (e.g., const int payday = 25;)
import 'admin_user_management_page.dart';

// Define Sort Options
enum SortOption {
  dateNewest,
  dateOldest,
  amountHigh,
  amountLow,
  salaryHigh,
  salaryLow,
}

class AdminHomepage extends StatefulWidget {
  final String adminName;
  final VoidCallback onLogoutTap;

  const AdminHomepage({
    super.key,
    required this.adminName,
    required this.onLogoutTap,
  });

  @override
  State<AdminHomepage> createState() => _AdminHomepageState();
}

class _AdminHomepageState extends State<AdminHomepage> {
  List<dynamic> _applications = [];
  bool _isLoading = true;
  String? _errorMessage;
  final _formatter = NumberFormat("#,##0");
  final _dateFormatter = DateFormat('MMM dd, yyyy');

  // --- MONEY POOL STATE ---
  int _poolBalance = 0;
  bool _isPoolLoading = true;

  // --- COUNTS STATE ---
  int _countAll = 0;
  int _countPending = 0;
  int _countOngoing = 0;
  int _countFinalized = 0;
  int _countRejected = 0;

  // --- SORTING & FILTERING STATE ---
  SortOption _currentSort = SortOption.dateNewest;
  String _searchQuery = "";
  String _statusFilter = "All";
  bool _isSearchBarVisible = false;
  final TextEditingController _searchController = TextEditingController();

  // --- BATCH PAYMENT STATE ---
  bool _isBatchPaying = false;

  @override
  void initState() {
    super.initState();
    _refreshAllData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshAllData() async {
    await Future.wait([
      _fetchAllApplications(),
      _fetchMoneyPool(),
    ]);
  }

  // --- 1. FETCH MONEY POOL ---
  Future<void> _fetchMoneyPool() async {
    if (!mounted) return;
    setState(() => _isPoolLoading = true);

    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/finance/pool');

    try {
      final response = await Api.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final fields = data['fields'];
        if (fields != null && fields['current_balance'] != null) {
          int balance =
              int.tryParse(fields['current_balance']['integerValue'] ?? "0") ??
                  0;
          if (mounted) {
            setState(() {
              _poolBalance = balance;
              _isPoolLoading = false;
            });
          }
        }
      } else {
        if (mounted) setState(() => _isPoolLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isPoolLoading = false);
    }
  }

  // --- 1.5 UPDATE MONEY POOL ---
  Future<void> _updatePoolBalance(int newAmount) async {
    int oldBalance = _poolBalance;
    setState(() => _poolBalance = newAmount);

    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/finance/pool?updateMask.fieldPaths=current_balance');

    try {
      final response = await Api.patch(
        url,
        body: jsonEncode({
          "fields": {
            "current_balance": {"integerValue": newAmount.toString()}
          }
        }),
      );

      if (response.statusCode != 200) {
        throw "Failed to update";
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: SelectableText("Pool balance updated successfully"),
            backgroundColor: Colors.green),
      );
    } catch (e) {
      setState(() => _poolBalance = oldBalance);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Error updating pool: $e"),
            backgroundColor: Colors.red),
      );
    }
  }

  // --- 1.6 SHOW EDIT DIALOG ---
  void _showEditPoolDialog() {
    TextEditingController amountController =
        TextEditingController(text: _formatter.format(_poolBalance));

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Edit Pool Balance"),
          content: TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              ThousandsSeparatorInputFormatter(),
            ],
            decoration: const InputDecoration(
              labelText: "Current Balance (THB)",
              prefixText: "฿ ",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                String rawValue = amountController.text.replaceAll(',', '');
                int? newAmount = int.tryParse(rawValue);

                if (newAmount != null) {
                  Navigator.pop(context);
                  _updatePoolBalance(newAmount);
                }
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  // --- 2. HELPER: SAFE NUMBER PARSING ---
  double _parseFirestoreNumber(dynamic field) {
    if (field == null) return 0.0;
    if (field['integerValue'] != null) {
      return double.tryParse(field['integerValue'].toString()) ?? 0.0;
    }
    if (field['doubleValue'] != null) {
      return (field['doubleValue'] as num).toDouble();
    }
    return 0.0;
  }

  // --- 3. HELPER: CALCULATE DISPLAY STATUS ---
  String _calculateDisplayStatus(Map<String, dynamic> fields) {
    String rawStatus =
        (fields['status']?['stringValue'] ?? "pending").toLowerCase();

    if (rawStatus == 'rejected') return 'Rejected';
    if (rawStatus == 'pending') return 'Pending';

    if (rawStatus == 'approved') {
      double totalLoanAmount = _parseFirestoreNumber(fields['loan_amount']);
      double totalPaid = 0.0;

      if (fields.containsKey('payment_history') &&
          fields['payment_history']['arrayValue'].containsKey('values')) {
        List<dynamic> history =
            fields['payment_history']['arrayValue']['values'];
        for (var item in history) {
          var amountField = item['mapValue']?['fields']?['amount'];
          totalPaid += _parseFirestoreNumber(amountField);
        }
      }

      bool isFullyPaid =
          totalPaid >= (totalLoanAmount - 1) && totalLoanAmount > 0;
      return isFullyPaid ? 'Finalized' : 'Ongoing';
    }

    return 'Pending';
  }

  // --- 4. HELPER: RECALCULATE COUNTS ---
  void _recalculateCounts() {
    int p = 0, o = 0, f = 0, r = 0;

    for (var app in _applications) {
      final fields = app['fields'];
      if (fields == null) continue;

      String status = _calculateDisplayStatus(fields);

      if (status == 'Pending')
        p++;
      else if (status == 'Ongoing')
        o++;
      else if (status == 'Finalized')
        f++;
      else if (status == 'Rejected') r++;
    }

    _countAll = _applications.length;
    _countPending = p;
    _countOngoing = o;
    _countFinalized = f;
    _countRejected = r;
  }

  // --- 5. FETCH APPLICATIONS ---
  Future<void> _fetchAllApplications() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications');

    try {
      final response = await Api.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<dynamic> docs = data['documents'] ?? [];

        setState(() {
          _applications = docs;
          _recalculateCounts();
          _sortApplications();
          _isLoading = false;
        });
      } else {
        throw "Error ${response.statusCode}: ${response.body}";
      }
    } catch (e) {
      print("Admin Error: $e");
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  void _sortApplications() {
    _applications.sort((a, b) {
      final fieldsA = a['fields'];
      final fieldsB = b['fields'];

      double getAmount(dynamic f) => _parseFirestoreNumber(f['loan_amount']);
      double getSalary(dynamic f) => _parseFirestoreNumber(f['salary']);
      DateTime getDate(dynamic f) {
        String? ts = f['timestamp']?['timestampValue'];
        return ts != null ? DateTime.parse(ts) : DateTime(1970);
      }

      switch (_currentSort) {
        case SortOption.dateNewest:
          return getDate(fieldsB).compareTo(getDate(fieldsA));
        case SortOption.dateOldest:
          return getDate(fieldsA).compareTo(getDate(fieldsB));
        case SortOption.amountHigh:
          return getAmount(fieldsB).compareTo(getAmount(fieldsA));
        case SortOption.amountLow:
          return getAmount(fieldsA).compareTo(getAmount(fieldsB));
        case SortOption.salaryHigh:
          return getSalary(fieldsB).compareTo(getSalary(fieldsA));
        case SortOption.salaryLow:
          return getSalary(fieldsA).compareTo(getSalary(fieldsB));
      }
    });
  }

  List<dynamic> get _filteredApplications {
    return _applications.where((app) {
      final fields = app['fields'];

      String displayStatus = _calculateDisplayStatus(fields);
      String name = (fields['name']?['stringValue'] ?? "").toLowerCase();
      String email = (fields['email']?['stringValue'] ?? "").toLowerCase();

      if (_statusFilter != "All" && displayStatus != _statusFilter) {
        return false;
      }

      if (_searchQuery.isNotEmpty) {
        String q = _searchQuery.toLowerCase();
        bool matches = name.contains(q) || email.contains(q);
        if (!matches) return false;
      }

      return true;
    }).toList();
  }

  void _onSortSelected(SortOption option) {
    setState(() {
      _currentSort = option;
      _sortApplications();
    });
  }

  String _getLabelWithCount(String filter) {
    int count = 0;
    switch (filter) {
      case "All":
        count = _countAll;
        break;
      case "Pending":
        count = _countPending;
        break;
      case "Ongoing":
        count = _countOngoing;
        break;
      case "Finalized":
        count = _countFinalized;
        break;
      case "Rejected":
        count = _countRejected;
        break;
    }
    return "$filter ($count)";
  }

  String _getDateFromFields(Map<String, dynamic> fields) {
    if (fields['timestamp'] != null &&
        fields['timestamp']['timestampValue'] != null) {
      DateTime dt = DateTime.parse(fields['timestamp']['timestampValue']);
      return _dateFormatter.format(dt);
    }
    return "-";
  }

  // --- BATCH PAYMENT LOGIC ---

  bool _hasPaidThisMonth(Map<String, dynamic> fields) {
    if (!fields.containsKey('payment_history') ||
        !fields['payment_history']['arrayValue'].containsKey('values')) {
      return false;
    }
    
    List<dynamic> history = fields['payment_history']['arrayValue']['values'];
    DateTime now = DateTime.now();

    for (var item in history) {
      var itemFields = item['mapValue']?['fields'];
      if (itemFields == null) continue;

      // SAFETY FIX: Check for stringValue as well, just like your other widget
      String? rawDate = itemFields['date']?['timestampValue'] ?? 
                        itemFields['date']?['stringValue'] ??
                        itemFields['timestamp']?['timestampValue'] ??
                        itemFields['timestamp']?['stringValue'];

      if (rawDate != null) {
        try {
          // Parse the date and convert to Local time to ensure the month matches perfectly
          DateTime paymentDate = DateTime.parse(rawDate).toLocal(); 
          
          if (paymentDate.year == now.year && paymentDate.month == now.month) {
            return true; // We found a payment for this month!
          }
        } catch (e) {
          print("Date parse error in _hasPaidThisMonth: $e");
        }
      }
    }
    return false;
  }

  bool get _shouldShowBatchPayBanner {
    DateTime now = DateTime.now();
    // Only show if we've reached payday
    if (now.day < payday) return false;

    // Only show if there is at least one Ongoing loan that hasn't been paid this month
    for (var app in _applications) {
      final fields = app['fields'];
      if (fields == null) continue;
      if (_calculateDisplayStatus(fields) == 'Ongoing' && !_hasPaidThisMonth(fields)) {
        return true; // We found an unpaid loan!
      }
    }
    return false; // Everyone is paid up for the month
  }

  // --- NEW: SAVE BATCH SUMMARY LOG ---
  Future<void> _saveBatchSummary(int totalLoans, int totalAmount, DateTime date) async {
    // This creates a new document in the 'batch_payment_logs' collection
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/batch_payment_logs');
    
    final payload = {
      "fields": {
        "total_loans": {"integerValue": totalLoans.toString()},
        "total_amount": {"integerValue": totalAmount.toString()},
        "timestamp": {"timestampValue": date.toUtc().toIso8601String()}
      }
    };

    try {
      final response = await Api.post(url, body: jsonEncode(payload));
      if (response.statusCode != 200) {
        print("Warning: Failed to save batch summary log: ${response.body}");
      }
    } catch (e) {
      print("Warning: Error saving batch summary: $e");
    }
  }

  Future<void> _processBatchPayments() async {
    setState(() => _isBatchPaying = true);
    int successCount = 0;
    int errorCount = 0;
    int totalCollectedAmount = 0; // Tracking the total cash for the pool
    DateTime now = DateTime.now();

    try {
      // 1. Find all Ongoing loans that haven't been paid this month
      List<dynamic> loansToPay = _applications.where((app) {
        final fields = app['fields'];
        return fields != null &&
               _calculateDisplayStatus(fields) == 'Ongoing' &&
               !_hasPaidThisMonth(fields); // Assuming you have this helper
      }).toList();

      // 2. Loop through and add a payment to each
      for (var app in loansToPay) {
        final docName = app['name']; 
        final fields = app['fields'];

        // --- THE MATH FIX ---
        // Grab total loan and months directly from the DB
        double totalLoan = _parseFirestoreNumber(fields['loan_amount']);
        
        int totalMonths = _parseFirestoreNumber(fields['months']).toInt();
        if (totalMonths == 0) {
          totalMonths = _parseFirestoreNumber(fields['term']).toInt();
        }

        // Grab existing history so we can count how many payments have already been made
        List<dynamic> existingHistory = [];
        if (fields.containsKey('payment_history') &&
            fields['payment_history']['arrayValue'].containsKey('values')) {
          existingHistory = List.from(fields['payment_history']['arrayValue']['values']);
        }

        // Count how many 'monthly' payments already exist to find our current month_index
        int pastMonthlyPayments = 0;
        for (var p in existingHistory) {
          if (p['mapValue']?['fields']?['type']?['stringValue'] == 'monthly') {
            pastMonthlyPayments++;
          }
        }
        
        // The index for THIS payment (0-based for the math, 1-based for the DB)
        int currentIndex = pastMonthlyPayments; 
        int nextMonthNum = pastMonthlyPayments + 1;

        int installmentInt = 0;

        if (totalLoan > 0 && totalMonths > 0) {
          // Calculate the exact same way PaymentScheduleWidget does!
          int baseDeduction = (totalLoan / totalMonths).floor();
          int remainder = totalLoan.toInt() - (baseDeduction * totalMonths);
          
          // Add 1 baht if we are still within the remainder months
          installmentInt = baseDeduction + (currentIndex < remainder ? 1 : 0);
        } else {
          // Ultimate fallback just in case
          installmentInt = _parseFirestoreNumber(fields['monthly_installment']).toInt();
        }

        // Failsafe: Do not record 0 baht payments
        if (installmentInt <= 0) {
          print("Skipping $docName: Calculated payment was 0.");
          errorCount++;
          continue; 
        }
        // --- END MATH FIX ---

        // Construct the new payment object exactly how Firestore wants it
        Map<String, dynamic> newPayment = {
          "mapValue": {
            "fields": {
              "amount": {"integerValue": installmentInt.toString()},
              "date": {"timestampValue": now.toUtc().toIso8601String()}, 
              "type": {"stringValue": "monthly"}, // Use "monthly" so your UI recognizes it!
              "month_index": {"integerValue": nextMonthNum.toString()}, // Add the month number
              "recorded_by": {"stringValue": "System (Auto-Batch)"} 
            }
          }
        };

        existingHistory.add(newPayment);

        // 3. Send update to Firestore
        final updateUrl = Uri.parse('https://firestore.googleapis.com/v1/$docName?updateMask.fieldPaths=payment_history');
        
        final payload = {
          "name": docName,
          "fields": {
            "payment_history": {
              "arrayValue": {
                "values": existingHistory
              }
            }
          }
        };

        try {
          final resp = await Api.patch(updateUrl, body: jsonEncode(payload));
          if (resp.statusCode == 200) {
            successCount++;
            totalCollectedAmount += installmentInt; // Add to our running total!
          } else {
            errorCount++;
            print("Batch Update Failed for $docName: ${resp.body}");
          }
        } catch (e) {
          errorCount++;
        }
      }

      // --- UPDATE POOL AND SAVE LOG ---
      if (successCount > 0) {
        // Add all collected money to the Money Pool collection
        await _updatePoolBalance(_poolBalance + totalCollectedAmount); // Assuming _poolBalance is a state variable you have
        
        // Save the summary log to the batch_payment_logs collection
        await _saveBatchSummary(successCount, totalCollectedAmount, now);
      }

      // Give Firestore a split-second to process before fetching the updated data
      await Future.delayed(const Duration(milliseconds: 500));
      await _refreshAllData(); // Or whatever your fetch function is called

      // Show Success UI
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Auto-Pay Complete! Added ฿${NumberFormat("#,##0").format(totalCollectedAmount)} to pool.\nSuccess: $successCount, Failed: $errorCount"),
            backgroundColor: errorCount == 0 ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 4),
          )
        );
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Batch Error: ${e.toString()}"), backgroundColor: Colors.red)
        );
      }
    } finally {
      setState(() => _isBatchPaying = false);
    }
  }

  // --- RESPONSIVE APP BAR BUILDERS ---

  Widget _buildMoneyPool() {
    return Center(
      child: InkWell(
        onTap: _showEditPoolDialog,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _isPoolLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      "Pool: ",
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                    SelectableText(
                      "฿${_formatter.format(_poolBalance)}",
                      style: TextStyle(
                          color: Colors.green.shade800,
                          fontWeight: FontWeight.bold,
                          fontSize: 14),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.edit, size: 14, color: Colors.grey[400]),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildSearchIcon() {
    return IconButton(
      icon: Icon(_isSearchBarVisible ? Icons.close : Icons.search,
          color: Colors.black87),
      onPressed: () {
        setState(() {
          _isSearchBarVisible = !_isSearchBarVisible;
          if (!_isSearchBarVisible) {
            _searchQuery = "";
            _searchController.clear();
          }
        });
      },
    );
  }

  List<Widget> _buildDesktopActions() {
    return [
      _buildMoneyPool(),
      _buildSearchIcon(),
      IconButton(
        icon: const Icon(Icons.refresh, color: Colors.black87),
        onPressed: _refreshAllData,
        tooltip: "Refresh Data",
      ),
      IconButton(
        icon: const Icon(Icons.people, color: Colors.black87),
        tooltip: "Manage Users",
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => const AdminUserManagementPage()),
          );
        },
      ),
      IconButton(
        icon: const Icon(Icons.logout, color: Colors.red),
        onPressed: widget.onLogoutTap,
        tooltip: "Logout",
      )
    ];
  }

  List<Widget> _buildMobileActions() {
    return [
      _buildSearchIcon(),
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: Colors.black87),
        onSelected: (value) {
          if (value == 'pool') _showEditPoolDialog();
          if (value == 'refresh') _refreshAllData();
          if (value == 'users') {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const AdminUserManagementPage()));
          }
          if (value == 'logout') widget.onLogoutTap();
          if (value.startsWith('sort_')) {
            int index = int.parse(value.split('_')[1]);
            _onSortSelected(SortOption.values[index]);
          }
        },
        itemBuilder: (context) {
          return [
            PopupMenuItem(
              value: 'pool',
              child: ListTile(
                leading: const Icon(Icons.account_balance_wallet,
                    color: Colors.green),
                title: SelectableText("Pool: ฿${_formatter.format(_poolBalance)}"),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'refresh',
              child: ListTile(
                leading: Icon(Icons.refresh),
                title: SelectableText("Refresh Data"),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'users',
              child: ListTile(
                leading: Icon(Icons.people),
                title: SelectableText("Manage Users"),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(enabled: false, child: SelectableText("Sort By:")),
            ...SortOption.values.asMap().entries.map((entry) {
              return PopupMenuItem(
                value: 'sort_${entry.key}',
                height: 40,
                child: Row(
                  children: [
                    Icon(
                      _currentSort == entry.value
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    SelectableText(_getSortSelectableText(entry.value),
                        style: const TextStyle(fontSize: 14)),
                  ],
                ),
              );
            }),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'logout',
              child: ListTile(
                leading: Icon(Icons.logout, color: Colors.red),
                title: SelectableText("Logout", style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ];
        },
      ),
    ];
  }

  String _getSortSelectableText(SortOption option) {
    switch (option) {
      case SortOption.dateNewest:
        return "Date (Newest)";
      case SortOption.dateOldest:
        return "Date (Oldest)";
      case SortOption.amountHigh:
        return "Amount (High)";
      case SortOption.amountLow:
        return "Amount (Low)";
      case SortOption.salaryHigh:
        return "Salary (High)";
      case SortOption.salaryLow:
        return "Salary (Low)";
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 550;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: _isSearchBarVisible
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.black),
                decoration: const InputDecoration(
                  hintText: "Search name or email...",
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Colors.black54),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              )
            : const Text("Dashboard",
                style: TextStyle(
                    color: Colors.black87, fontWeight: FontWeight.bold)),
        actions: isSmallScreen ? _buildMobileActions() : _buildDesktopActions(),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: Column(
        children: [
          // --- BATCH PAY BANNER ---
          if (!_isLoading && _shouldShowBatchPayBanner)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: Colors.blue.shade50,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.monetization_on, color: Colors.blue.shade800),
                      const SizedBox(width: 8),
                      const Text(
                        "Monthly Payday is here!",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade800,
                      foregroundColor: Colors.white,
                      elevation: 0,
                    ),
                    onPressed: _isBatchPaying ? null : _processBatchPayments,
                    icon: _isBatchPaying 
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.check_circle_outline, size: 20),
                    label: Text(_isBatchPaying ? "Processing..." : "Mark All Paid"),
                  )
                ],
              ),
            ),

          // --- RESPONSIVE FILTERS ---
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              alignment: WrapAlignment.center,
              children: [
                "All",
                "Pending",
                "Ongoing",
                "Finalized",
                "Rejected"
              ].map((filter) {
                bool isSelected = _statusFilter == filter;
                return FilterChip(
                  label: Text(_getLabelWithCount(filter)),
                  selected: isSelected,
                  onSelected: (bool selected) {
                    setState(() => _statusFilter = filter);
                  },
                  backgroundColor: Colors.grey[100],
                  selectedColor: Colors.blue.shade100,
                  labelStyle: TextStyle(
                      color: isSelected ? Colors.blue.shade900 : Colors.black87,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                        color:
                            isSelected ? Colors.blue.shade200 : Colors.transparent),
                  ),
                  checkmarkColor: Colors.blue.shade900,
                );
              }).toList(),
            ),
          ),
          const Divider(height: 1),

          Expanded(child: _buildBody(isSmallScreen)),
        ],
      ),
    );
  }

  Widget _buildBody(bool isSmallScreen) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
          child: SelectableText("Error: $_errorMessage",
              style: const TextStyle(color: Colors.red)));
    }

    final displayList = _filteredApplications;

    if (displayList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            const SelectableText("No applications found.",
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 16),
            ElevatedButton(
                onPressed: _refreshAllData, child: const Text("Refresh Data"))
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshAllData,
      child: isSmallScreen
          ? _buildMobileList(displayList)
          : _buildDesktopTable(displayList),
    );
  }

  Widget _buildDesktopTable(List<dynamic> displayList) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Colors.grey.shade200)),
        child: SizedBox(
          width: double.infinity,
          child: Theme(
            data: Theme.of(context).copyWith(
              dividerColor: Colors.grey[200],
              highlightColor: Colors.blue.withOpacity(0.05),
              splashColor: Colors.blue.withOpacity(0.1),
            ),
            child: DataTable(
              horizontalMargin: 24,
              columnSpacing: 24,
              showCheckboxColumn: false,
              headingRowColor: MaterialStateProperty.all(Colors.grey[50]),
              columns: const [
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('User')),
                DataColumn(label: Text('Email')),
                DataColumn(label: Text('Application Date')),
                DataColumn(label: Text('Loan Amount'), numeric: true),
              ],
              rows: displayList.map((app) {
                final fields = app['fields'];
                final name = app['name'];
                String loanId = name.split('/').last;
                String displayStatus = _calculateDisplayStatus(fields);
                String userName =
                    fields['name']?['stringValue'] ?? "Unknown User";
                String email = fields['email']?['stringValue'] ?? "-";
                String dateStr = _getDateFromFields(fields);

                double totalPayback =
                    _parseFirestoreNumber(fields['loan_amount']);
                double principal =
                    ((totalPayback / 1.05) + 0.01).floorToDouble();

                return DataRow(
                  onSelectChanged: (_) => _navigateToDetails(fields, loanId),
                  cells: [
                    DataCell(
                      Tooltip(
                        message: displayStatus,
                        waitDuration: Duration.zero,
                        child: Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.centerLeft,
                          color: Colors.transparent,
                          child: Icon(
                            _getStatusIcon(displayStatus),
                            color: _getStatusColor(displayStatus),
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    DataCell(SelectableText(userName,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(SelectableText(email,
                        style: TextStyle(color: Colors.grey[600]))),
                    DataCell(SelectableText(dateStr)),
                    DataCell(SelectableText("฿${_formatter.format(principal)}",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14))),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileList(List<dynamic> displayList) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: displayList.length,
      itemBuilder: (context, index) {
        final app = displayList[index];
        final fields = app['fields'];
        final name = app['name'];
        String loanId = name.split('/').last;

        String userName = fields['name']?['stringValue'] ?? "Unknown";
        String email = fields['email']?['stringValue'] ?? "-";
        String displayStatus = _calculateDisplayStatus(fields);
        String dateStr = _getDateFromFields(fields);

        double totalPayback = _parseFirestoreNumber(fields['loan_amount']);
        double principal = ((totalPayback / 1.05) + 0.01).floorToDouble();

        return Card(
          elevation: 0,
          color: Colors.white,
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade200)),
          child: InkWell(
            onTap: () => _navigateToDetails(fields, loanId),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(_getStatusIcon(displayStatus),
                      color: _getStatusColor(displayStatus), size: 24),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(userName,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15)),
                            ),
                            SelectableText("฿${_formatter.format(principal)}",
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: Colors.black87)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(email,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Colors.grey[700], fontSize: 13)),
                            ),
                            SelectableText(dateStr,
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right, color: Colors.grey[400], size: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _navigateToDetails(
      Map<String, dynamic> fields, String loanId) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) => LoanDetailsPage(
                  loanData: fields,
                  loanId: loanId,
                  onUpdate: _refreshAllData,
                  currentUserType: 'admin',
                  isAdmin: true,
                )));
    _refreshAllData();
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'finalized':
        return Colors.green;
      case 'ongoing':
        return Colors.blue;
      case 'rejected':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'finalized':
        return Icons.check_circle;
      case 'ongoing':
        return Icons.sync;
      case 'rejected':
        return Icons.cancel;
      default:
        return Icons.access_time_filled;
    }
  }
}

class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  static const separator = ',';

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) {
      return newValue.copyWith(text: '');
    }

    String oldValueText = oldValue.text.replaceAll(separator, '');
    String newValueText = newValue.text.replaceAll(separator, '');

    if (int.tryParse(newValueText) == null) {
      return oldValue;
    }

    final formatter = NumberFormat("#,###");
    String newText = formatter.format(int.parse(newValueText));

    int offset =
        newValue.selection.baseOffset + (newText.length - oldValue.text.length);

    return newValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: offset > 0 ? offset : 0),
    );
  }
}