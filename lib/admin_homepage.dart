import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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
    required this.onLogoutTap
  });

  @override
  State<AdminHomepage> createState() => _AdminHomepageState();
}

class _AdminHomepageState extends State<AdminHomepage> {
  List<dynamic> _applications = [];
  bool _isLoading = true;
  String? _errorMessage;
  final _formatter = NumberFormat("#,##0");
  
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
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final fields = data['fields'];
        if (fields != null && fields['current_balance'] != null) {
          int balance = int.tryParse(fields['current_balance']['integerValue'] ?? "0") ?? 0;
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

  // --- 2. HELPER: SAFE NUMBER PARSING ---
  // Firestore sometimes returns 'integerValue' and sometimes 'doubleValue'
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
    String rawStatus = (fields['status']?['stringValue'] ?? "pending").toLowerCase();

    if (rawStatus == 'rejected') return 'Rejected';
    if (rawStatus == 'pending') return 'Pending';

    // If approved, check if fully paid
    if (rawStatus == 'approved') {
      double totalLoanAmount = _parseFirestoreNumber(fields['loan_amount']);
      double totalPaid = 0.0;

      if (fields.containsKey('payment_history') && 
          fields['payment_history']['arrayValue'].containsKey('values')) {
          
          List<dynamic> history = fields['payment_history']['arrayValue']['values'];
          for (var item in history) {
            // Check nested map fields for 'amount'
            var amountField = item['mapValue']?['fields']?['amount'];
            totalPaid += _parseFirestoreNumber(amountField);
          }
      }

      // Check if paid (allow small buffer for float errors)
      bool isFullyPaid = totalPaid >= (totalLoanAmount - 1) && totalLoanAmount > 0;
      
      return isFullyPaid ? 'Finalized' : 'Ongoing';
    }

    return 'Pending'; // Default fallback
  }

  // --- 4. HELPER: RECALCULATE COUNTS ---
  // This must be called inside setState
  void _recalculateCounts() {
    int p = 0, o = 0, f = 0, r = 0;
    
    for (var app in _applications) {
      final fields = app['fields'];
      if (fields == null) continue;

      String status = _calculateDisplayStatus(fields);
      
      if (status == 'Pending') p++;
      else if (status == 'Ongoing') o++;
      else if (status == 'Finalized') f++;
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
      final response = await http.get(url);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<dynamic> docs = data['documents'] ?? [];
        
        // Update state with new data AND recalculate counts immediately
        setState(() {
          _applications = docs;
          _recalculateCounts(); // Force recount with new data
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
        case SortOption.dateNewest: return getDate(fieldsB).compareTo(getDate(fieldsA));
        case SortOption.dateOldest: return getDate(fieldsA).compareTo(getDate(fieldsB));
        case SortOption.amountHigh: return getAmount(fieldsB).compareTo(getAmount(fieldsA));
        case SortOption.amountLow: return getAmount(fieldsA).compareTo(getAmount(fieldsB));
        case SortOption.salaryHigh: return getSalary(fieldsB).compareTo(getSalary(fieldsA));
        case SortOption.salaryLow: return getSalary(fieldsA).compareTo(getSalary(fieldsB));
      }
    });
  }

  List<dynamic> get _filteredApplications {
    return _applications.where((app) {
      final fields = app['fields'];
      
      String displayStatus = _calculateDisplayStatus(fields);
      String name = (fields['name']?['stringValue'] ?? "").toLowerCase();
      String email = (fields['email']?['stringValue'] ?? "").toLowerCase();
      
      // Filter Logic
      if (_statusFilter != "All" && displayStatus != _statusFilter) {
        return false;
      }

      // Search Logic
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
      case "All": count = _countAll; break;
      case "Pending": count = _countPending; break;
      case "Ongoing": count = _countOngoing; break;
      case "Finalized": count = _countFinalized; break;
      case "Rejected": count = _countRejected; break;
    }
    return "$filter ($count)";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: _isSearchBarVisible 
          ? TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: Colors.black),
              decoration: const InputDecoration(
                hintText: "Search Name or Email...",
                border: InputBorder.none,
                hintStyle: TextStyle(color: Colors.black54),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            )
          : const Text("Admin Dashboard", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        
        actions: [
          // Money Pool Display
          Center(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.shade700,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))
                ]
              ),
              child: _isPoolLoading 
                ? const SizedBox(
                    width: 16, height: 16, 
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.account_balance_wallet, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        "฿${_formatter.format(_poolBalance)}",
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
            ),
          ),

          IconButton(
            icon: Icon(_isSearchBarVisible ? Icons.close : Icons.search, color: Colors.black87),
            onPressed: () {
              setState(() {
                _isSearchBarVisible = !_isSearchBarVisible;
                if (!_isSearchBarVisible) {
                  _searchQuery = "";
                  _searchController.clear();
                }
              });
            },
          ),
          
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black87),
            onPressed: _refreshAllData,
            tooltip: "Refresh Data",
          ),

          PopupMenuButton<SortOption>(
            icon: const Icon(Icons.sort, color: Colors.black87),
            tooltip: "Sort Applications",
            onSelected: _onSortSelected,
            itemBuilder: (context) => [
              const PopupMenuItem(value: SortOption.dateNewest, child: Text("Date (Newest First)")),
              const PopupMenuItem(value: SortOption.dateOldest, child: Text("Date (Oldest First)")),
              const PopupMenuDivider(),
              const PopupMenuItem(value: SortOption.amountHigh, child: Text("Loan Amount (Highest)")),
              const PopupMenuItem(value: SortOption.amountLow, child: Text("Loan Amount (Lowest)")),
              const PopupMenuDivider(),
              const PopupMenuItem(value: SortOption.salaryHigh, child: Text("Monthly Salary (Highest)")),
              const PopupMenuItem(value: SortOption.salaryLow, child: Text("Monthly Salary (Lowest)")),
            ],
          ),

          IconButton(
            icon: const Icon(Icons.people, color: Colors.black87),
            tooltip: "Manage Users",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AdminUserManagementPage()),
              );
            },
          ),
          
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.red),
            onPressed: widget.onLogoutTap,
            tooltip: "Logout",
          )
        ],
      ),
      body: Container( 
        child: Column(
          children: [
            const SizedBox(height: 100), 
            
            // --- FILTER CHIPS ROW ---
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: ["All", "Pending", "Ongoing", "Finalized", "Rejected"].map((filter) {
                  bool isSelected = _statusFilter == filter;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_getLabelWithCount(filter)),
                      selected: isSelected,
                      onSelected: (bool selected) {
                        setState(() => _statusFilter = filter);
                      },
                      backgroundColor: Colors.white,
                      selectedColor: Colors.blue.withOpacity(0.2),
                      labelStyle: TextStyle(
                        color: isSelected ? Colors.blue : Colors.black,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      checkmarkColor: Colors.blue,
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 10),

            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(child: Text("Error: $_errorMessage", style: const TextStyle(color: Colors.red)));
    }

    final displayList = _filteredApplications; 

    if (displayList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text("No applications match your search.", style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 16),
            if (_applications.isNotEmpty) 
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _searchQuery = "";
                    _statusFilter = "All";
                    _searchController.clear();
                    _isSearchBarVisible = false;
                  });
                }, 
                child: const Text("Clear Filters")
              )
            else 
              ElevatedButton(onPressed: _refreshAllData, child: const Text("Refresh"))
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshAllData,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), 
        itemCount: displayList.length,
        itemBuilder: (context, index) {
          final app = displayList[index];
          final fields = app['fields'];
          final name = app['name']; 
          
          String userName = fields['name']?['stringValue'] ?? "Unknown User";
          String email = fields['email']?['stringValue'] ?? "Unknown";
          
          String displayStatus = _calculateDisplayStatus(fields);
          
          double totalPayback = _parseFirestoreNumber(fields['loan_amount']);
          double principal = ((totalPayback / 1.05) + 0.01).floorToDouble();
          
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor: _getStatusColor(displayStatus).withOpacity(0.1),
                child: Icon(_getStatusIcon(displayStatus), color: _getStatusColor(displayStatus)),
              ),
              title: Text(userName, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(email, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                  const SizedBox(height: 4),
                  Text("Request: ${_formatter.format(principal)} THB", style: const TextStyle(color: Colors.black87)),
                ],
              ),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _getStatusColor(displayStatus),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  displayStatus.toUpperCase(), 
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)
                ),
              ),
              onTap: () async {
                String loanId = name.split('/').last;

                await Navigator.push(
                  context, 
                  MaterialPageRoute(
                    builder: (context) => LoanDetailsPage(
                      loanData: fields, 
                      loanId: loanId,
                      onUpdate: _refreshAllData, 
                      currentUserType: 'admin', 
                      isAdmin: true, 
                    )
                  )
                );
                _refreshAllData(); 
              },
            ),
          );
        },
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'finalized': return Colors.green;
      case 'ongoing': return Colors.blue;
      case 'rejected': return Colors.red;
      default: return Colors.orange;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'finalized': return Icons.check_circle;
      case 'ongoing': return Icons.sync;
      case 'rejected': return Icons.close;
      default: return Icons.hourglass_empty;
    }
  }
}