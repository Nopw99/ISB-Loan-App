import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api_helper.dart';
import 'dart:convert';
import 'dart:async';
import 'package:intl/intl.dart';
import 'loan_details_page.dart';
import 'secrets.dart';
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
  final _dateFormatter = DateFormat('MMM dd, yyyy'); // Added Date Formatter

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
    // Optimistic update
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
            content: Text("Pool balance updated successfully"),
            backgroundColor: Colors.green),
      );
    } catch (e) {
      // Revert on failure
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

  // --- HELPER: GET DATE FROM FIELDS ---
  String _getDateFromFields(Map<String, dynamic> fields) {
    if (fields['timestamp'] != null &&
        fields['timestamp']['timestampValue'] != null) {
      DateTime dt = DateTime.parse(fields['timestamp']['timestampValue']);
      return _dateFormatter.format(dt);
    }
    return "-";
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
                    Text(
                      "Pool: ",
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                    Text(
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
                title: Text("Pool: ฿${_formatter.format(_poolBalance)}"),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'refresh',
              child: ListTile(
                leading: Icon(Icons.refresh),
                title: Text("Refresh Data"),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'users',
              child: ListTile(
                leading: Icon(Icons.people),
                title: Text("Manage Users"),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(enabled: false, child: Text("Sort By:")),
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
                    Text(_getSortText(entry.value),
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
                title: Text("Logout", style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ];
        },
      ),
    ];
  }

  List<PopupMenuEntry<SortOption>> _buildSortItems() {
    return SortOption.values.map((option) {
      return PopupMenuItem(
        value: option,
        child: Text(_getSortText(option)),
      );
    }).toList();
  }

  String _getSortText(SortOption option) {
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
    
    // CHANGED: Breakpoint set to 550px as requested
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
          // --- RESPONSIVE FILTERS ---
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              // CHANGED: Centered the filters
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
          child: Text("Error: $_errorMessage",
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
            const Text("No applications found.",
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 16),
            ElevatedButton(
                onPressed: _refreshAllData, child: const Text("Refresh Data"))
          ],
        ),
      );
    }

    // --- SWITCH BETWEEN TABLE AND LIST VIEW ---
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
              // This removes the splash effect if you want it cleaner, 
              // or keep it to show interaction.
              highlightColor: Colors.blue.withOpacity(0.05),
              splashColor: Colors.blue.withOpacity(0.1),
            ),
            child: DataTable(
              horizontalMargin: 24,
              columnSpacing: 24,
              // CHANGED: Hides the checkbox column so onSelectChanged works like a standard click
              showCheckboxColumn: false, 
              headingRowColor: MaterialStateProperty.all(Colors.grey[50]),
              columns: const [
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('User')),
                DataColumn(label: Text('Email')),
                DataColumn(label: Text('Date')),
                DataColumn(label: Text('Amount'), numeric: true),
                // CHANGED: Removed Action Column
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
                  // CHANGED: This makes the whole row clickable
                  onSelectChanged: (_) => _navigateToDetails(fields, loanId),
                  cells: [
                    DataCell(
                      Tooltip(
                        message: displayStatus,
                        // CHANGED: Zero duration for instant appearance
                        waitDuration: Duration.zero, 
                        // CHANGED: Wrapped in Container for bigger hitbox
                        child: Container(
                          width: 40, 
                          height: 40,
                          alignment: Alignment.centerLeft,
                          color: Colors.transparent, // Ensures hit test works on whitespace
                          child: Icon(
                            _getStatusIcon(displayStatus),
                            color: _getStatusColor(displayStatus),
                            size: 20, // Icon size remains small
                          ),
                        ),
                      ),
                    ),
                    DataCell(Text(userName,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(Text(email,
                        style: TextStyle(color: Colors.grey[600]))),
                    DataCell(Text(dateStr)),
                    DataCell(Text("฿${_formatter.format(principal)}",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14))),
                    // CHANGED: Removed Action Cell
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  // --- MOBILE: COMPACT LIST VIEW ---
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
                  // Status Icon
                  Icon(_getStatusIcon(displayStatus),
                      color: _getStatusColor(displayStatus), size: 24),
                  const SizedBox(width: 16),

                  // Content
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
                            Text("฿${_formatter.format(principal)}",
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
                            Text(dateStr,
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

// --- UTILITY: THOUSANDS SEPARATOR FORMATTER ---
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
        newValue.selection.baseOffset + (newText.length - newValue.text.length);

    return newValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: offset > 0 ? offset : 0),
    );
  }
}