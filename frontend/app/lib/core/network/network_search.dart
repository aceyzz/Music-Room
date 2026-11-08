// import 'package:app/core/controllers/command_controller.dart';
// import 'package:app/core/controllers/search_controller.dart';

// abstract class NetworkSearch<Source, T, R> {
//   final CommandController<Source, T> commandController;
//   final SearchController<R> searchController;

//   NetworkSearch({
//     required this.commandController,
//     required this.searchController,
//   });

//   // Abstract hook to let subclasses define how items are extracted from [T]
//   List<R> extractItems(T? data);

//   // Dynamic computed getter for the final filtered items
//   List<R> get filteredItems {
//     final rawItems = extractItems(commandController.data);
//     return searchController.filter(rawItems);
//   }

//   bool get isLoading => commandController.isLoading && !commandController.hasData;
//   bool get hasError => commandController.error != null && !commandController.hasData;
//   String? get errorMessage => commandController.error;
// }