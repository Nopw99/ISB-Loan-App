import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data'; 
import 'package:intl/intl.dart'; 
import 'package:file_saver/file_saver.dart'; 
import 'loan_details_page.dart'; 
import 'main.dart'; 
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
  
  // --- COUNTS STATE ---
  int _countAll = 0;
  int _countPending = 0;
  int _countApproved = 0;
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
    _fetchAllApplications();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
        _applications = docs;
        
        // --- COUNT LOGIC ---
        int p = 0, a = 0, r = 0;
        for (var doc in docs) {
          String status = (doc['fields']['status']?['stringValue'] ?? "").toLowerCase();
          if (status == 'pending') p++;
          else if (status == 'approved') a++;
          else if (status == 'rejected') r++;
        }
        
        _countAll = docs.length;
        _countPending = p;
        _countApproved = a;
        _countRejected = r;
        // -------------------

        _sortApplications(); 
        setState(() => _isLoading = false);
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

      int getAmount(dynamic f) => int.tryParse(f['loan_amount']?['integerValue'] ?? '0') ?? 0;
      int getSalary(dynamic f) => int.tryParse(f['salary']?['integerValue'] ?? '0') ?? 0;
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
      String status = (fields['status']?['stringValue'] ?? "pending").toLowerCase();
      String name = (fields['name']?['stringValue'] ?? "").toLowerCase();
      String email = (fields['email']?['stringValue'] ?? "").toLowerCase();
      
      if (_statusFilter != "All" && status != _statusFilter.toLowerCase()) {
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

  // Helper to get count for label
  String _getLabelWithCount(String filter) {
    int count = 0;
    switch (filter) {
      case "All": count = _countAll; break;
      case "Pending": count = _countPending; break;
      case "Approved": count = _countApproved; break;
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
            onPressed: _fetchAllApplications,
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
        decoration: kAppBackground, 
        child: Column(
          children: [
            const SizedBox(height: 100), 
            
            // --- FILTER CHIPS ROW (UPDATED WITH COUNTS) ---
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: ["All", "Pending", "Approved", "Rejected"].map((filter) {
                  bool isSelected = _statusFilter == filter;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_getLabelWithCount(filter)), // <--- Shows "Pending (5)"
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
              ElevatedButton(onPressed: _fetchAllApplications, child: const Text("Refresh"))
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchAllApplications,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), 
        itemCount: displayList.length,
        itemBuilder: (context, index) {
          final app = displayList[index];
          final fields = app['fields'];
          final name = app['name']; 
          
          String userName = fields['name']?['stringValue'] ?? "Unknown User";
          String email = fields['email']?['stringValue'] ?? "Unknown";
          String status = fields['status']?['stringValue'] ?? "pending";
          
          double totalPayback = double.tryParse(fields['loan_amount']?['integerValue'] ?? "0") ?? 0;
          double principal = ((totalPayback / 1.05) + 0.01).floorToDouble();
          
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor: _getStatusColor(status).withOpacity(0.1),
                child: Icon(_getStatusIcon(status), color: _getStatusColor(status)),
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
                  color: _getStatusColor(status),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status.toUpperCase(), 
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
                      onUpdate: _fetchAllApplications, 
                      currentUserType: 'admin', 
                    )
                  )
                );
                _fetchAllApplications(); 
              },
            ),
          );
        },
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved': return Colors.green;
      case 'rejected': return Colors.red;
      default: return Colors.orange;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'approved': return Icons.check;
      case 'rejected': return Icons.close;
      default: return Icons.hourglass_empty;
    }
  }
}