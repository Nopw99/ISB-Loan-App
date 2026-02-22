import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class PaymentScheduleWidget extends StatelessWidget {
  final double loanAmount;
  final int months;
  final double monthlySalary;
  final bool isApproved;
  final bool isAdmin;
  final bool isProcessing;
  final List<dynamic> paidMonths; 
  final Function(int, double) onMarkPaid;
  final VoidCallback onCustomPayment;

  const PaymentScheduleWidget({
    super.key,
    required this.loanAmount,
    required this.months,
    required this.monthlySalary,
    required this.isApproved,
    required this.isAdmin,
    required this.isProcessing,
    required this.paidMonths,
    required this.onMarkPaid,
    required this.onCustomPayment,
  });

  // --- LOGIC: Distribute extra bahts to the first few months ---
  double _calculateInstallment(int monthIndex, double total, int totalMonths) {
    if (totalMonths == 0) return 0;
    
    int totalInt = total.round();
    int baseAmount = totalInt ~/ totalMonths; 
    int remainder = totalInt % totalMonths;   

    if (monthIndex < remainder) {
      return (baseAmount + 1).toDouble();
    } else {
      return baseAmount.toDouble();
    }
  }

  // --- LOGIC: Safely check if a month is paid ---
  bool _checkIfPaid(int index) {
    return paidMonths.any((payment) {
      if (payment is int) return payment == index;
      
      if (payment is Map) {
        // REST API nested format
        if (payment.containsKey('mapValue')) {
          final fields = payment['mapValue']['fields'];
          if (fields != null && fields.containsKey('month_index')) {
            final monthIndexData = fields['month_index'];
            if (monthIndexData != null && monthIndexData.containsKey('integerValue')) {
              int? parsedIndex = int.tryParse(monthIndexData['integerValue'].toString());
              return parsedIndex == index;
            }
          }
        }
        
        // Flat Map fallback
        if (payment.containsKey('month_index')) {
          return payment['month_index'] == index || payment['month_index'] == index.toString();
        }
        if (payment.containsKey('monthIndex')) {
           return payment['monthIndex'] == index || payment['monthIndex'] == index.toString();
        }
      }
      return false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currencyFormat = NumberFormat("#,##0", "en_US");
    
    double totalPaidAmount = 0;
    int totalPaidCount = 0;
    
    for (int i = 0; i < months; i++) {
      if (_checkIfPaid(i)) {
        totalPaidAmount += _calculateInstallment(i, loanAmount, months);
        totalPaidCount++;
      }
    }

    double remainingAmount = loanAmount - totalPaidAmount;
    double progress = months > 0 ? totalPaidCount / months : 0;

    return Column(
      children: [
        // --- SUMMARY HEADER ---
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Repayment Progress",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "${(progress * 100).toStringAsFixed(0)}%",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: progress == 1.0 ? Colors.green : Colors.blue,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.grey.shade200,
                color: progress == 1.0 ? Colors.green : Colors.blue,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _summaryColumn("Paid", "${currencyFormat.format(totalPaidAmount)} THB", Colors.green),
                  _summaryColumn("Remaining", "${currencyFormat.format(remainingAmount > 0 ? remainingAmount : 0)} THB", Colors.orange[800]!),
                ],
              ),
            ],
          ),
        ),

        // --- SCHEDULE LIST ---
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: months,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              bool isPaid = _checkIfPaid(index);
              double exactAmountDue = _calculateInstallment(index, loanAmount, months);
              
              // NEW LOGIC: A month is only payable if it's the first month, or the previous month is already paid.
              bool isPreviousPaid = index == 0 ? true : _checkIfPaid(index - 1);
              
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isPaid ? Colors.green.shade200 : Colors.grey.shade300,
                  ),
                ),
                color: isPaid ? Colors.green.shade50 : Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      // Month Number Badge
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: isPaid ? Colors.green : Colors.blue.shade100,
                        child: Text(
                          "${index + 1}",
                          style: TextStyle(
                            color: isPaid ? Colors.white : Colors.blue.shade800,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      
                      // Details
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Month ${index + 1}",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${currencyFormat.format(exactAmountDue)} THB",
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),

                      // Status / Action Button
                      if (isPaid)
                        const Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.green),
                            SizedBox(width: 4),
                            Text("Paid", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                          ],
                        )
                      else if (isApproved && isAdmin)
                        // Show button for admins, but disable it if the previous month isn't paid yet
                        ElevatedButton(
                          onPressed: (isProcessing || !isPreviousPaid) 
                              ? null 
                              : () => onMarkPaid(index, exactAmountDue),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                            disabledForegroundColor: Colors.grey.shade600,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text("Mark Paid"),
                        )
                      else
                        // Normal users just see "Pending"
                        Text(
                          "Pending",
                          style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold),
                        )
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // --- CUSTOM PAYMENT BUTTON (Admins Only Now) ---
        if (isApproved && isAdmin)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: isProcessing ? null : onCustomPayment,
                icon: const Icon(Icons.payment),
                label: const Text("Make Custom Payment"),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: const BorderSide(color: Colors.blue),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _summaryColumn(String label, String amount, Color amountColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
        const SizedBox(height: 4),
        Text(amount, style: TextStyle(color: amountColor, fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }
}