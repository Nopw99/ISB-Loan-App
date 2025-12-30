import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class PaymentScheduleWidget extends StatelessWidget {
  final double loanAmount;
  final int months;
  final double monthlySalary;

  const PaymentScheduleWidget({
    super.key, 
    required this.loanAmount, 
    required this.months,
    required this.monthlySalary,
  });

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat("#,##0");

    // --- CALCULATION LOGIC ---
    int totalLoanInt = loanAmount.round();
    int salaryInt = monthlySalary.round();
    
    if (months <= 0) return const Center(child: Text("Invalid Duration"));

    int baseDeduction = (totalLoanInt / months).floor();
    int remainder = totalLoanInt - (baseDeduction * months);

    List<Map<String, dynamic>> schedule = [];
    double totalDeduction = 0;
    double totalFinalSalary = 0;

    for (int i = 0; i < months; i++) {
      int currentDeduction = baseDeduction + (i < remainder ? 1 : 0);
      int finalSal = salaryInt - currentDeduction;
      
      totalDeduction += currentDeduction;
      totalFinalSalary += finalSal;

      schedule.add({
        'month': i + 1,
        'salary': salaryInt,
        'deduction': currentDeduction,
        'final': finalSal,
      });
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Payment Schedule", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              
              // --- HEADER ---
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: const [
                    Expanded(child: Text('Month', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                    Expanded(child: Text('Salary', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold))),
                    Expanded(child: Text('Loan Payment', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red))),
                    Expanded(child: Text('Final Salary', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green))),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // --- ROWS (FIXED: Uses Column instead of ListView) ---
              Column(
                children: [
                  for (int i = 0; i < schedule.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(child: Text("${schedule[i]['month']}", textAlign: TextAlign.center)),
                          Expanded(child: Text(formatter.format(schedule[i]['salary']), textAlign: TextAlign.right)),
                          Expanded(child: Text("-${formatter.format(schedule[i]['deduction'])}", textAlign: TextAlign.right, style: const TextStyle(color: Colors.red))),
                          Expanded(child: Text(formatter.format(schedule[i]['final']), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green))),
                        ],
                      ),
                    ),
                    // Add divider if it's not the last item
                    if (i < schedule.length - 1) const Divider(height: 1),
                  ]
                ],
              ),
              
              const SizedBox(height: 8),

              // --- FOOTER (TOTALS) ---
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text("$months Months", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                    Expanded(child: Text(formatter.format(salaryInt * months), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                    Expanded(child: Text("-${formatter.format(totalDeduction)}", textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 16))),
                    Expanded(child: Text(formatter.format(totalFinalSalary), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 16))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}