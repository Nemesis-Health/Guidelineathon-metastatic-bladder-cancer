getCohortAttritionViewResults <- function(inclusionResultTable, maxRuleId) {
  numberToBitString <- function(numbers) {
    vapply(numbers, function(number) {
      if (number == 0) {
        return("0")
      }
      bitString <- character()
      while (number > 0) {
        bitString <- c(as.character(number %% 2), bitString)
        number <- number %/% 2
      }
      paste(bitString, collapse = "")
    }, character(1))
  }
  
  bitsToMask <- function(bits) {
    positions <- seq_along(bits) - 1
    number <- sum(bits * 2 ^ positions)
    return(number)
  }
  
  ruleToMask <- function(ruleId) {
    bits <- rep(1, ruleId)
    mask <- bitsToMask(bits)
    return(mask)
  }
  
  inclusionResultTable <- inclusionResultTable %>%
    dplyr::mutate(inclusionRuleMaskBitString = numberToBitString(inclusionRuleMask))
  
  output <- c()
  
  for (i in (1:maxRuleId)) {
    suffixString <- numberToBitString(ruleToMask(i))
    output[[i]] <- inclusionResultTable %>%
      dplyr::filter(
        endsWith(
          x = inclusionRuleMaskBitString,
          suffix = suffixString
        )
      ) %>%
      dplyr::group_by(
        cohortDefinitionId,
        modeId
      ) %>%
      dplyr::summarise(
        personCount = sum(personCount),
        .groups = "drop"
      ) %>%
      dplyr::ungroup() %>%
      dplyr::mutate(id = i)
  }
  
  output <- dplyr::bind_rows(output)
  output <- bind_rows(
    dplyr::slice(output, 1) %>% 
      mutate(
        id = 0,
        personCount = sum(inclusionResultTable$personCount)
      ),
    output
  )
  
  return(output)
}