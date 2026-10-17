/**
 * @description: **JobSequenceFunctionCatalog** -- Optional interface for a job sequence handler to list the function
 * names its executeFunction method handles, so the Sequence Jobs tab can offer them in a dropdown. Handlers that don't
 * implement it still work; their function names are typed in.
 * @author: Gary Butler
 * @date: 10/17/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/17/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
global interface JobSequenceFunctionCatalog {
    /**
     * @description Lists the function names this handler's executeFunction method handles.
     *
     * @return The function names, e.g. FieldShift
     */
    List<String> getFunctionNames();
}
