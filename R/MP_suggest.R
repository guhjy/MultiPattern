## Helper function for suggesting configurations for a MultiMetric meta-analysis
##
##



##' Suggest a set of clustering analyses for a dataset
##'
##' This function can take some time to execute for large datasets. This is
##' because the function applies principal component decompositions to parts of the
##' input data and stores the intermediate results in the MP object. This computation
##' speeds up subsequent steps of the MultiMetric analysis.
##' 
##' @param MP MultiMetric configuration object
##' @param data character. Name of dataset defined in MP.
##' @param verbose logical. Set FALSE to make the function silent, TRUE to see cat updates.
##' 
##' @export
MPsuggestConfig = function(MP, data, verbose=TRUE) {
    
    ## Some hard checks on the inputs
    if (class(data)!="character") {
        stop("data must be a character string\n")
    }
    if (length(data)!=1) {
        stop("data must have length 1\n")
    }
    if (!(data %in% names(MP$data))) {
        stop("data is not defined in MP object\n")
    }       
    
    ## capture MP expression for assignment at the end
    captureMP = deparse(substitute(MP))
    
    ## get the actual data matrix
    dd = MP$data[[data]]
    
    if (verbose & object.size(dd)>1e7) {
        cat("This may take a little time. Please wait... ")
    }

    num.start = length(MP$configs)
    
    ## ###############################################################################
    ## helper function to compute some summary stats from vectors
    mystats = function(x) {
        x = x[is.finite(x)]
        n = length(x)
        xmean = mean(x)
        mu2 = sum((x-xmean)^2)
        mu3 = sum((x-xmean)^3)
        mu4 = sum((x-xmean)^4)
        c(skew=n^(1/2)*mu3/mu2^(3/2), kurtosis=n*mu4/(mu2^2))
    }       
    ## ###############################################################################
    
    ## create an ad-hoc classification of features by data range (integer/real, etc)
    feature.types = data.frame(Column=colnames(dd),
        skew=0, ex.kurtosis=0, n.unique=0, stringsAsFactors=F)
    rownames(feature.types) = colnames(dd)
    for (nowcol in colnames(dd)) {
        nowdata = as.numeric(dd[,nowcol])
        nowu = length(unique(nowdata))
        nowstats = mystats(nowdata)
        feature.types[nowcol, c("skew", "ex.kurtosis", "n.unique")] =
            c(nowstats[1], nowstats[2]-3, nowu)
    }
    if (length(colnames(dd))>0) {
        rm(nowdata, nowu, nowstats)
    }
    
    skewth = min(1, log2(ncol(dd))/(2*sqrt(nrow(dd))))
    feature.class = rep("real", nrow(feature.types))
    names(feature.class) = rownames(feature.types)
    feature.class[feature.types[, "n.unique"]==1] = "single"
    feature.class[feature.types[, "n.unique"]==2] = "bin"
    feature.class[abs(feature.types[, "skew"])>skewth &
                  feature.types[, "n.unique"]==2] = "bin.skew"
    feature.class[feature.types[, "n.unique"]<nrow(dd)/2 &
                  feature.types[, "n.unique"]>2] = "multi"
    feature.class[feature.types[, "n.unique"]<nrow(dd)/2 &
                  feature.types[, "n.unique"]>2 &
                  abs(feature.types[, "skew"])>skewth] = "multi.skew"
    feature.class[feature.types[, "n.unique"]>nrow(dd)/2 &
                  abs(feature.types[, "skew"])>skewth] = "real.skew"     
    
    ## avoid splits of features with just one feature
    feature.table = table(feature.class)
    for (ii in c("bin", "multi", "real")) {
        iiskew = paste0(ii, ".skew")
        if (ii %in% names(feature.table) & iiskew %in% names(feature.table)) {
            if (feature.table[ii]==1 | feature.table[iiskew]==1) {
                feature.class[feature.class %in% c(ii, iiskew)] = ii
            }
        }
    }    

    ## organize the features into a list by data type
    feature.class = split(names(feature.class), feature.class)
    ## avoid working with features with a single value
    feature.class[["single"]] = NULL
    if (length(feature.class)==0) {
        stop("data does not appear to have distinct values\n")
    }
    MP$auto = feature.class
    
    config.prefix = "[auto]:"
    
    
    ## ###############################################################################
    ## Start modifications of MP object with new configurations
    
    ## add configurations to MP based on these categories of variables
    distconf = p0(config.prefix, data, ":", names(feature.class))
    MPaddConfig(MP, paste0(distconf, ":euclidean"),
                data, preprocess=feature.class, dist.fun=dist.euclidean)
    MPaddConfig(MP, paste0(distconf, ":canberra"),
                data, preprocess=feature.class, dist.fun=dist.canberra)
    rm(distconf)

    
    ## for real-valued data, add pca  and rpca
    for (nowf in c("real", "real.skew")) {
        if (nowf %in% names(feature.class)) {
            ## for pca and rpca, avoid features with NAs
            nowdd = dd[, feature.class[[nowf]], drop=FALSE]
            nowdd.ok = apply(nowdd, 2, function(x) {sum(!is.finite(x))==0})
            nowdd = nowdd[, nowdd.ok, drop=FALSE]
            if (ncol(nowdd)>0) {            
                data.name = paste0(data, ":", nowf)
                MPaddData(MP, setNames(list(nowdd), data.name))        
                MPeasyConfig(MP, data=data.name, config.prefix=config.prefix, type=c("pca"))
                ## here can remove the temporary datasets (the pca and rpca types
                ## would have by now created their own helper tables)
                MPremove(MP, data=data.name)                
            }
        }
    }
    
    
    ## for all the feature types, add clust-based distances
    okf = c("bin", "bin.skew", "multi", "multi.skew", "real", "real.skew")
    okf = okf[okf%in% names(feature.class)]
    for (nowf in okf) {
        nowfeatures = feature.class[[nowf]]
        ## add hclust distances
        clustconf = paste0(config.prefix, data, ":", nowf, ":clust.")
        for (nowk in c(2, 3)) {
            ## add clust-based distances for this feature class
            ## but only if there are enough feature to make the clustering work
            if (nrow(dd)>(2*nowk)+2) {
                for (ncm in c("average", "single", "complete", "pam")) {
                    if (ncm %in% c("average", "single", "complete")) {
                        nowdreg = MPdistFactory(method="hclust",
                            clust.k=nowk, clust.method=ncm, clust.alt=FALSE)
                        nowdalt = MPdistFactory(method="hclust",
                            clust.k=nowk, clust.method=ncm, clust.alt=TRUE)
                        ncm.init = toupper(substring(ncm, 1, 1))                        
                    } else if (ncm == "pam") {
                        nowdreg = MPdistFactory(method="pam",
                            clust.k=nowk, clust.method="pam", clust.alt=FALSE)
                        nowdalt = MPdistFactory(method="pam",
                            clust.k=nowk, clust.method="pam", clust.alt=TRUE)
                        ncm.init = "P"
                    }
                    MPaddConfig(MP, paste0(clustconf, ncm.init, nowk,"reg"),
                                data.name=data, preprocess=nowfeatures, dist.fun=nowdreg)
                    MPaddConfig(MP, paste0(clustconf, ncm.init, nowk,"alt"),
                                data.name=data, preprocess=nowfeatures, dist.fun=nowdalt)
                    rm(nowdreg, nowdalt, ncm.init)                
                }                                
            }                                
        }

        MPeasyConfig(MP, config.prefix=config.prefix, subspace.prefix=nowf,
                     type="subspaceR", data=data, preprocess=colnames(nowdd))
        rm(nowfeatures, clustconf)
    }


    ## add some random configurations
    Nrandom = MP$settings$num.random
    random.preprocess = vector("list", Nrandom)
    names(random.preprocess) = as.character(1:Nrandom)
    random.preprocess = random.preprocess[
        which(!paste0(config.prefix, "rnorm.", 1:Nrandom) %in% names(MP$configs))]
    if (length(random.preprocess)>0) {
        MPaddConfig(MP, paste0(config.prefix, "rnorm"), data, preprocess=random.preprocess,
                    dist.fun=dist.rnorm)
    }

    ## finish with some updates to the user
    if (verbose & object.size(dd)>1e7) {
        cat("done\n")
    }    
    num.end = length(MP$configs)
    if (verbose) {
        cat(p0("MPsuggestConfig created ", num.end-num.start, " configurations\n"))
    }
    
    assign(captureMP, MP, parent.frame())
    invisible(MP)  
}





##' Suggest a set of clustering analyses for a dataset
##'
##' This function can take some time to execute for large datasets. This is
##' because the function applies principal component decompositions to parts of the
##' input data and stores the intermediate results in the MP object. This computation
##' speeds up subsequent steps of the MultiMetric analysis.
##' 
##' @param MP MultiMetric configuration object
##' @param data character. Name of dataset defined in MP.
##' @param random.perm integer. Set to number of randomized configurations for each
##' suggested analysis type
##' @param random.generic integer. Number of generic randomized configurations
##' @param clust.types character. Types of clustering-based distances to 
##' 
##' I think this is deprecated
MPsuggestConfigLong = function(MP, data, random.perm=0, random.generic=100,
    clust.types=c("average", "pam")) {
    
    ## Some hard checks on the inputs
    if (class(data)!="character") {
        stop("data must be a character string\n")
    }
    if (length(data)!=1) {
        stop("data must have length 1\n")
    }
    if (!(data %in% names(MP$data))) {
        stop("data is not defined in MP object\n")
    }    
    clust.ok = sum(clust.types %in% c("average", "single", "complete", "pam"))
    if (clust.ok<length(clust.types)) {
        stop("clust.types must be in the set average, single, complete, pam\n")
    }
    
    ## capture MP expression for assignment at the end
    captureMP = deparse(substitute(MP))
    
    ## get the actual data matrix
    dd = MP$data[[data]]
    
    if (object.size(dd)>1e7) {
        cat("This may take a little time. Please wait... ")
    }
    
    ## ###############################################################################
    ## helper function to compute some summary stats from vectors
    mystats = function(x) {
        x = x[is.finite(x)]
        n = length(x)
        xmean = mean(x)
        mu2 = sum((x-xmean)^2)
        mu3 = sum((x-xmean)^3)
        mu4 = sum((x-xmean)^4)
        c(skew=n^(1/2)*mu3/mu2^(3/2), kurtosis=n*mu4/(mu2^2))
    }       
    ## ###############################################################################
    
    ## create an ad-hoc classification of features by data range (integer/real, etc)
    feature.types = data.frame(Column=colnames(dd),
        skew=0, ex.kurtosis=0, n.unique=0, stringsAsFactors=F)
    rownames(feature.types) = colnames(dd)
    for (nowcol in colnames(dd)) {
        nowdata = as.numeric(dd[,nowcol])
        nowu = length(unique(nowdata))
        nowstats = mystats(nowdata)
        feature.types[nowcol, c("skew", "ex.kurtosis", "n.unique")] =
            c(nowstats[1], nowstats[2]-3, nowu)
    }
    if (length(colnames(dd))>0) {
        rm(nowdata, nowu, nowstats)
    }
    
    skewth = min(1, log2(ncol(dd))/(2*sqrt(nrow(dd))))
    feature.class = rep("real", nrow(feature.types))
    names(feature.class) = rownames(feature.types)
    feature.class[feature.types[, "n.unique"]==1] = "single"
    feature.class[feature.types[, "n.unique"]==2] = "bin"
    feature.class[abs(feature.types[, "skew"])>skewth &
                  feature.types[, "n.unique"]==2] = "bin.skew"
    feature.class[feature.types[, "n.unique"]<nrow(dd)/2 &
                  feature.types[, "n.unique"]>2] = "multi"
    feature.class[feature.types[, "n.unique"]<nrow(dd)/2 &
                  feature.types[, "n.unique"]>2 &
                  abs(feature.types[, "skew"])>skewth] = "multi.skew"
    feature.class[feature.types[, "n.unique"]>nrow(dd)/2 &
                  abs(feature.types[, "skew"])>skewth] = "real.skew"     
    
    ## avoid splits of features with just one feature
    feature.table = table(feature.class)
    for (ii in c("bin", "multi", "real")) {
        iiskew = paste0(ii, ".skew")
        if (ii %in% names(feature.table) & iiskew %in% names(feature.table)) {
            if (feature.table[ii]==1 | feature.table[iiskew]==1) {
                feature.class[feature.class %in% c(ii, iiskew)] = ii
            }
        }
    }    

    ## organize the features into a list by data type
    feature.class = split(names(feature.class), feature.class)
    ## avoid working with features with a single value
    feature.class[["single"]] = NULL
    if (length(feature.class)==0) {
        stop("data does not appear to have distinct values\n")
    }
    
    config.prefix = "[auto]:"

    ## create a list with randomized configurations
    if (random.perm>0) {
        rpreprocess = newv("list", random.perm)
        for (i in 1:random.perm) {
            rpreprocess[[i]] = MPrandomizeMatrix
        }
    }
    
    ## ###############################################################################
    ## Start modifications of MP object with new configurations

    
    ## add configurations to MP based on these categories of variables
    distconf = p0(config.prefix, data, ":", names(feature.class))
    MPaddConfig(MP, paste0(distconf, ":euclidean"),
                data, preprocess=feature.class, dist.fun=dist.euclidean)
    MPaddConfig(MP, paste0(distconf, ":canberra"),
                data, preprocess=feature.class, dist.fun=dist.canberra)
    if (random.perm>0) {
        for (nowf in names(feature.class)) {
            distconf = p0(config.prefix, data, ":", nowf)
            MPaddConfig(MP, p0(distconf, ":euclidean.rshuffle"),
                        data.name=data, preprocess=newv("list", random.perm),
                        dist.fun=function(x) {dist.perm(x, dist.method="euclidean") })
            MPaddConfig(MP, p0(distconf, ":canberra.rshuffle"), 
                        data.name=data, preprocess=newv("list", random.perm),
                        dist.fun=function(x) {dist.perm(x, dist.method="canberra") })
        }
    }
        
    ## create a list with randomized configurations
    if (random.perm>0) {
        rpreprocess = newv("list", random.perm)
        for (i in 1:random.perm) {
            rpreprocess[[i]] = MPrandomizeMatrix
        }
    }
    
    ## for real-valued data, add pca  and rpca
    for (nowf in c("real", "real.skew")) {
        if (nowf %in% names(feature.class)) {
            ## for pca and rpca, avoid features with NAs
            nowdd = dd[, feature.class[[nowf]], drop=FALSE]
            nowdd.ok = apply(nowdd, 2, function(x) {sum(!is.finite(x))==0})
            nowdd = nowdd[, nowdd.ok, drop=FALSE]
            if (ncol(nowdd)>0) {            
                data.name = paste0(data, ":", nowf)
                MPaddData(MP, setNames(list(nowdd), data.name))        
                MPeasyConfig(MP, data=data.name,
                             config.prefix=config.prefix, type=c("pca", "rpca"),
                             PCAexplain = min(4, ncol(nowdd)))
                if (random.perm>0) {
                    ## add random configurationa for each of the pca components
                    MPaddConfig(MP, p0(config.prefix, data.name, ".pca:rshuffle"),
                                data.name=p0(data.name, ".pca"),
                                preprocess=newv("list", random.perm), dist.fun=dist.perm)
                    MPaddConfig(MP, p0(config.prefix, data.name, ".rpcaL.pca:rshuffle"),
                                data.name=p0(data.name, ".rpcaL.pca"),
                                preprocess=newv("list", random.perm), dist.fun=dist.perm)
                    MPaddConfig(MP, p0(config.prefix, data.name, ".rpcaS.pca:rshuffle"),
                                data.name=p0(data.name, ".rpcaS.pca"),
                                preprocess=newv("list", random.perm), dist.fun=dist.perm)
                }
                ## here can remove the temporary datasets (the pca and rpca types
                ## would have by now created their own helper tables)
                MPremove(MP, data=data.name)
            }
        }
    }
    
    ## for all the feature types, add clust-based distances
    okf = c("bin", "bin.skew", "multi", "multi.skew", "real", "real.skew")
    okf = okf[okf%in% names(feature.class)]
    for (nowf in okf) {
        nowfeatures = feature.class[[nowf]]
        ## add hclust distances
        clustconf = paste0(config.prefix, data, ":", nowf, ":clust.")
        for (nowk in c(2, 3)) {
            ## add clust-based distances for this feature class
            ## but only if there are enough feature to make the clustering work
            if (nrow(dd)>(2*nowk)+2) {
                for (ncm in clust.types) {
                    if (ncm %in% c("average", "single", "complete")) {
                        nowdreg = MPdistFactory(method="hclust",
                            clust.k=nowk, clust.method=ncm, clust.alt=FALSE)
                        nowdalt = MPdistFactory(method="hclust",
                            clust.k=nowk, clust.method=ncm, clust.alt=TRUE)
                        ncm.init = toupper(substring(ncm, 1, 1))                        
                    } else if (ncm == "pam") {
                        nowdreg = MPdistFactory(method="pam",
                            clust.k=nowk, clust.method="pam", clust.alt=FALSE)
                        nowdalt = MPdistFactory(method="pam",
                            clust.k=nowk, clust.method="pam", clust.alt=TRUE)
                        ncm.init = "P"
                    }
                    MPaddConfig(MP, paste0(clustconf, ncm.init, nowk,"reg"),
                                data.name=data, preprocess=nowfeatures, dist.fun=nowdreg)
                    MPaddConfig(MP, paste0(clustconf, ncm.init, nowk,"alt"),
                                data.name=data, preprocess=nowfeatures, dist.fun=nowdalt)
                    if (random.perm>0) {
                        MPaddConfig(MP, p0(clustconf, ncm.init, nowk, "reg.rshuffle"),
                                    data.name=data, preprocess=rpreprocess[1:ceiling(random.perm/2)],
                                    dist.fun=nowdreg)
                        MPaddConfig(MP, p0(clustconf, ncm.init, nowk, "alt.rshuffle"),
                                    data.name=data, preprocess=rpreprocess[1:ceiling(random.perm/2)],
                                    dist.fun=nowdalt)
                    }
                    rm(nowdreg, nowdalt, ncm.init)                
                }                                
            }                                
        }
        rm(nowfeatures, clustconf)

    }
    
    ## add some random configurations
    Nrandom = random.generic
    random.preprocess = vector("list", Nrandom)
    names(random.preprocess) = as.character(1:Nrandom)
    random.preprocess = random.preprocess[
        which(!paste0(config.prefix, "rnorm:", 1:Nrandom) %in% names(MP$configs))]
    if (length(random.preprocess)>0) {
        MPaddConfig(MP, paste0(config.prefix, "rnorm"), data, preprocess=random.preprocess,
                    dist.fun=dist.rnorm)
    }
    if (object.size(dd)>1e7) {
        cat("done\n")
    }
    
    assign(captureMP, MP, parent.frame())
    invisible(MP)  
}





