###############################################################################
## This script is for mJAM (multi-ethnic Joint Analysis of Marginal statistics) 
## with Forward selection as the model selection method.

###############  Section 0 : load required functions  #################

## ... ##
# N_GWAS = c(5000, 5000, 5000)
# X_ref = list(RefDosage_P1,RefDosage_P2,RefDosage_P3)
# Marg_Result = MargBeta
# EAF_Result = EAF
# condp_cut = 0.05/50; within_pop_threshold = 0.50
# across_pop_threshold = 0.20
# filter_rare = TRUE; rare_freq = c(0.2, 0.4, 0.4)
# Pr_Med_cut = 0

# N_GWAS = N_Sample
# X_ref = Input_Dosage
# Marg_Result = Marg_Result
# EAF_Result = MAF_Result
# condp_cut = 0.05/N_SNP
# within_pop_threshold = 0.50
# across_pop_threshold = 0.20
# Pr_Med_cut = 0

## change the name of subset_EUR and has_dosage SNP
## ... ##


mJAM_Forward <- function(N_GWAS, X_ref, 
                         Marg_Result, EAF_Result, 
                         condp_cut = NULL, 
                         within_pop_threshold = 0.50, 
                         across_pop_threshold = 0.20, 
                         coverage = 0.95,
                         Pr_Med_cut = 0.2,
                         filter_rare = FALSE, 
                         rare_freq = NULL){
  ## Set parameters
  library(dplyr)
  library(tibble)
  N_SNP <- numSNPs <- nrow(Marg_Result)
  if(is.null(condp_cut)){condp_cut <- 0.05/N_SNP}
  
  ## if filter_rare, then remove rare SNPs 
  if(filter_rare == TRUE){
    ## check rare frequency cutoff
    if(is.null(rare_freq)){
      stop("Please specify a vector of minor allele frequency thresholds (between 0 and 0.5).")
    }else if(length(rare_freq)!=length(X_ref)){
      stop("Length of rare_freq does not match with the number of populations")
    }else{
      ## filter SNPs whose MAF < rare_freq in "ALL" population 
      rare_freq_matrix = matrix(rep(rare_freq,numSNPs), byrow = TRUE, nrow = numSNPs, ncol = length(rare_freq))
      rare_freq_true = abs(EAF_Result[,2:ncol(EAF_Result)]-0.5)>0.5-rare_freq_matrix
      rare_filter_id = which(rowMeans(rare_freq_true,na.rm=T)==1)
      if(length(rare_filter_id)>0){
        ## filter Marg_Result and EAF_Result and X_ref
        Marg_Result = Marg_Result[-rare_filter_id,]
        EAF_Result = EAF_Result[-rare_filter_id,]
        for(i in 1:length(X_ref)){X_ref[[i]] = X_ref[[i]][,-rare_filter_id]}
      }
    }
  }
  
  if(typeof(filter_rare)!="logical"){
    stop("Please specify filter_rare to be either TRUE or FALSE.")
  }
  
  Original_Input_Dosage <- X_ref
  Input_MarglogOR <- Input_MargSElogOR <- Input_MAF <- feMeta_w <- feMeta_w_x_beta <- vector("list", length(X_ref))
  for(pop in 1:length(X_ref)){
    Input_MarglogOR[[pop]] <- Marg_Result[,2*pop]
    Input_MargSElogOR[[pop]] <- Marg_Result[,2*pop+1]
    Input_MAF[[pop]] <- EAF_Result[,1+pop]
    names(Input_MarglogOR[[pop]]) <- Marg_Result[,1]
    names(Input_MargSElogOR[[pop]]) <- Marg_Result[,1]
    names(Input_MAF[[pop]]) <- EAF_Result[,1]
    feMeta_w[[pop]] <- 1/Marg_Result[,2*pop+1]^2
    feMeta_w_x_beta[[pop]] <- feMeta_w[[pop]]*Marg_Result[,2*pop]
  }
  feMeta_se <- sqrt(1/Reduce(`+`,feMeta_w))
  feMeta_mean <- Reduce(`+`,feMeta_w_x_beta)/Reduce(`+`,feMeta_w)
  
  ## --- Check missing data
  numEthnic <- length(Input_MarglogOR)
  missing_tbl <- tibble(missing_ethnic_idx = integer(), missing_snp_idx = integer())
  
  for(i in 1:numEthnic){
    temp_missing_gwas <- union(which(is.na(Input_MarglogOR[[i]])), which(is.na(Input_MargSElogOR[[i]])))
    temp_missing_gwas <- union(temp_missing_gwas, which(is.na(Input_MAF[[i]])))
    temp_missing_dosage <- which(colSums(is.na(X_ref[[i]]))>0)
    if(length(temp_missing_gwas)>0){
      missing_tbl <- missing_tbl %>% add_row(missing_ethnic_idx =i, missing_snp_idx = temp_missing_gwas)
    }
    if(length(temp_missing_dosage)>0){
      missing_tbl <- missing_tbl %>% add_row(missing_ethnic_idx =i, missing_snp_idx = temp_missing_dosage)
    }
  }
  missing_tbl <- distinct(missing_tbl)
  
  ## --- Calculate the LD matrix of X_ref
  Dosage_cor <- vector("list",length(X_ref))
  for(i in 1:length(X_ref)){
    if (nrow(missing_tbl) > 0 && i%in%missing_tbl$missing_ethnic_idx){
      ## --- Get missing SNP index
      temp_missing_snp_idx <- filter(missing_tbl, missing_ethnic_idx == i) %>% pull(missing_snp_idx)
      ## --- Get Dosage_cor with complete SNP
      temp_Dosage_cor <- cor(X_ref[[i]][,-temp_missing_snp_idx])^2
      ## --- Fill in missing SNPs with zeros
      Dosage_cor[[i]] <- diag(1, nrow = numSNPs, ncol = numSNPs)
      Dosage_cor[[i]][-temp_missing_snp_idx, -temp_missing_snp_idx] <- temp_Dosage_cor
    }else{
      Dosage_cor[[i]] <- cor(X_ref[[i]])^2
    }
  }
  
  ## -- Calculate sufficient statistics 
  GItGI <- GIty <- yty <- yty_med <- vector("list", numEthnic)
  for (i in 1:numEthnic){
    if (nrow(missing_tbl) > 0 && i%in%missing_tbl$missing_ethnic_idx){
      ## --- Get missing SNP index
      temp_missing_snp_idx <- filter(missing_tbl, missing_ethnic_idx == i) %>% pull(missing_snp_idx)
      ## --- Get GItGI, GIty, yty with complete SNP
      temp_X_ref <- X_ref[[i]][,-temp_missing_snp_idx]
      temp_MAFs <- Input_MAF[[i]][-temp_missing_snp_idx]
      temp_GItGI <- get_XtX(N_outcome = N_GWAS[i], Gl = temp_X_ref, maf = temp_MAFs)
      ##
      temp.marginal.betas <- Input_MarglogOR[[i]][-temp_missing_snp_idx]
      temp.marginal.se <- Input_MargSElogOR[[i]][-temp_missing_snp_idx]
      temp.GIty <- get_z(maf = temp_MAFs, betas = temp.marginal.betas, N_outcome = N_GWAS[i])
      ##
      # yty[[i]] <- get_yty(maf = temp_MAFs, N_outcome = N_GWAS[i], betas = temp.marginal.betas, betas.se = temp.marginal.se)
      ## --- Fill in missing SNPs with zeros
      GItGI[[i]] <- matrix(0, nrow = numSNPs, ncol = numSNPs)
      GItGI[[i]][-temp_missing_snp_idx, -temp_missing_snp_idx] <- temp_GItGI
      GIty[[i]] <- rep(0, numSNPs)
      GIty[[i]][-temp_missing_snp_idx] <- temp.GIty
    }else{
      GItGI[[i]] <- get_XtX(N_outcome = N_GWAS[i], Gl = X_ref[[i]], 
                            maf = Input_MAF[[i]])
      GIty[[i]] <- get_z(maf = Input_MAF[[i]], 
                         betas = Input_MarglogOR[[i]], N_outcome = N_GWAS[i])
    }
    temp_yty <- get_yty(maf = Input_MAF[[i]], N_outcome = N_GWAS[i], 
                        betas = Input_MarglogOR[[i]], 
                        betas.se = Input_MargSElogOR[[i]])
    yty[[i]] <- temp_yty$yTy.all
    yty_med[[i]] <- temp_yty$yTy.est
    colnames(GItGI[[i]]) <- rownames(GItGI[[i]]) <- Marg_Result[,1] 
    names(GIty[[i]]) <- names(yty[[i]]) <- Marg_Result[,1] 
  }
  ## Identify rare variants 
  rare_pct <- rowMeans(abs(EAF_Result[,2:ncol(EAF_Result)]-0.5)>0.48)
  rare_SNPs <- Marg_Result[which(rare_pct>=0.5),1]
  if(length(rare_SNPs)==0){rare_SNPs <- NULL}
  
  ## Run Forward selection
  iter_count <- 0
  selected_ids <- NULL
  prev_index_snp <- NULL
  pruned_snps <- NULL
  condp_list <- NULL
  curr_min_condp <- 0
  prev_min_condp <- 0
  all_CS <- NULL
  subset_EUR <- has_dosage_SNP <- Marg_Result$SNP
  GItGI_curr <- GItGI
  GIty_curr <- GIty
  yty_curr <- yty
  
  while(iter_count >= 0){
    ## step 1: select top SNPs in the remaining list
    ## selected_id should be the ID in subset_EUR
    if(length(unique(pruned_snps))==N_SNP){break}
    if(iter_count == 0){Input_id = NULL}else{Input_id = match(selected_ids, subset_EUR)}
    
    ## get the id of rare SNPs in remaining SNPs
    if(sum(rare_SNPs %in% subset_EUR)>0){
      rare_id = match(rare_SNPs, subset_EUR)
      rare_id = rare_id[!is.na(rare_id)]
    }else{
      rare_id = NULL
    }
    
    ## get the conditional p-values of all remaining SNPs
    newFS_RES <- mJAM_get_condp(GItGI = GItGI_curr, GIty = GIty_curr, yty = yty_curr, 
                                yty_med = yty_med, N_GWAS = N_GWAS, selected_id = Input_id,
                                use_median_yty_ethnic = NULL, rare_id = rare_id)
    
    ## output mJAM marginal p and meta marginal p 
    if(iter_count == 0){
      marginal_est <- tibble(SNP = subset_EUR, 
                             mJAM_effect = signif(newFS_RES$effect_est, digits = 3), 
                             feMeta_effect = feMeta_mean,
                             mJAM_se = signif(newFS_RES$se_est, digits = 3),
                             feMeta_se = feMeta_se) %>% 
        mutate(mJAM_logp = Rmpfr::pnorm(abs(mJAM_effect/mJAM_se),lower.tail = F,log.p = T)+log(2),
               feMeta_logp = Rmpfr::pnorm(abs(feMeta_effect/feMeta_se),lower.tail = F,log.p = T)+log(2)) %>% 
        mutate(mJAM_log10p = signif(mJAM_logp/log(10), 4), 
               feMeta_log10p = signif(feMeta_logp/log(10),4))
    }
    
    if(newFS_RES$condp_min > log(condp_cut)) {break}
    
    curr_index_snp <- subset_EUR[newFS_RES$which_condp_min]
    selected_ids <- c(selected_ids, curr_index_snp)
    condp_list <- c(condp_list, newFS_RES$condp_min)
    message(paste("No.", iter_count+1,"selected index SNP:", curr_index_snp))
    
    ## step 2: construct credible sets based on the selected SNP
    curr_CS <- mJAM_build_CS(X_id = curr_index_snp,
                             prev_X_list = prev_index_snp,
                             All_id = subset_EUR,
                             PrCS_weights = "Pr(M_C)", 
                             coverage = coverage,
                             GItGI_curr = GItGI_curr, GIty_curr = GIty_curr, 
                             yty_curr = yty_curr, yty_med = yty_med, 
                             N_GWAS = N_GWAS, rare_SNPs = rare_SNPs,
                             Pr_Med_cut = Pr_Med_cut)

    ## step 3: prune out CS SNPs and SNPs in LD with index SNP; subset input statistics
    curr_CS_snp <- filter(curr_CS, CS_in == T) %>% pull(CS_SNP)
    pruned_snps <- c(pruned_snps, curr_index_snp)
    curr_LD_snp <- mJAM_LDpruning(target = match(curr_index_snp,has_dosage_SNP),
                                  testing = match(has_dosage_SNP[-match(pruned_snps,has_dosage_SNP)],has_dosage_SNP),
                                  R = Dosage_cor,
                                  within_thre = within_pop_threshold, across_thre = across_pop_threshold)
    pruned_snps <- c(pruned_snps,has_dosage_SNP[c(curr_LD_snp$remove_within, curr_LD_snp$remove_across)])
    
    all_CS <- rbind(all_CS, curr_CS) 
    
    ## step 4: update input statistics
    if(length(pruned_snps)>0){
      subset_EUR <- has_dosage_SNP[-match(pruned_snps, has_dosage_SNP)]
    }
    subset_EUR <- union(subset_EUR, selected_ids)
    subset_EUR <- has_dosage_SNP[has_dosage_SNP%in%subset_EUR]
    message(paste(length(unique(pruned_snps)), "SNPs got pruned.", length(subset_EUR), "SNPs left."))
    
    if(length(subset_EUR)>1){
      for(e in 1:numEthnic){
        GItGI_curr[[e]] <- GItGI[[e]][subset_EUR, subset_EUR] 
        GIty_curr[[e]] <- GIty[[e]][subset_EUR] 
        yty_curr[[e]] <- yty[[e]][subset_EUR] 
        colnames(GItGI_curr[[e]]) <- rownames(GItGI_curr[[e]]) <- subset_EUR
        names(GIty_curr[[e]]) <- names(yty_curr[[e]]) <- subset_EUR
      }
      ## step 5: continue to the next iteration
      iter_count <- iter_count+1
      prev_index_snp <- c(prev_index_snp, curr_index_snp)
      message("Continue to next round of index SNP selection.")
    }else{
      ## step 5: continue to the next iteration
      iter_count <- iter_count+1
      prev_index_snp <- c(prev_index_snp, curr_index_snp)
      break
    }
    
  }
  message("Analysis ended.")
  
  if(!is.null(selected_ids)){
    final_condp_selected <- mJAM_get_condp_selected(GItGI = GItGI, GIty = GIty, yty = yty,
                                                    N_GWAS = N_GWAS,yty_med = yty_med,
                                                    selected_id = selected_ids,
                                                    rare_SNPs = rare_SNPs)
    
    if(length(selected_ids)>1){
      finalp = final_condp_selected$condp[,1]
    }else{
      finalp =  final_condp_selected$condp
    }
    
    MULTI_index <- tibble(SNP = selected_ids, cond_log10p = condp_list/log(10), 
                          final_log10p = finalp/log(10), pcut = condp_cut)
  }else{
    message("No index SNP selected in this region.")
    MULTI_index = NULL
    all_CS = NULL
  }
  
  return(list(index = MULTI_index, 
              cs = all_CS, 
              mJAM_marg_est = marginal_est[,c(1,2,4,8)], 
              QC_marg_est = marginal_est))
}